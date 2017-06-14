#!/usr/bin/env perl

package Git::Hooks::CheckCommit;
# ABSTRACT: Git::Hooks plugin to enforce commit policies

use 5.010;
use utf8;
use strict;
use warnings;
use Error ':try';
use Git::Hooks;
use Git::Repository::Log;
use List::MoreUtils qw/any none/;

my $PKG = __PACKAGE__;
(my $CFG = __PACKAGE__) =~ s/.*::/githooks./;

#############
# Grok hook configuration, check it and set defaults.

sub _setup_config {
    my ($git) = @_;

    my $config = $git->get_config();

    $config->{lc $CFG} //= {};

    return;
}

##########

sub match_errors {
    my ($git, $commit) = @_;

    my $errors = 0;

    my $cache = $git->cache($PKG);

    unless (exists $cache->{identity}) {
        $cache->{identity} = {};
        foreach my $info (qw/name email/) {
            foreach my $regexp ($git->get_config($CFG => $info)) {
                $regexp =~ s/^(\!?)//;
                push @{$cache->{identity}{$info}{$1}}, qr/$regexp/; ## no critic (ProhibitCaptureWithoutTest)
            }
        }
    }

    if (keys %{$cache->{identity}}) {
        foreach my $info (qw/name email/) {
            if (my $checks = $cache->{identity}{$info}) {
                foreach my $who (qw/author committer/) {
                    my $who_info = "${who}_${info}";
                    my $data     = $commit->$who_info;

                    unless (any  { $data =~ $_ } @{$checks->{''}}) {
                        $git->error($PKG, "commit @{[$commit->commit]} $who $info ($data) does not match any positive githooks.checkcommit.$info option");
                        ++$errors;
                    }

                    unless (none { $data =~ $_ } @{$checks->{'!'}}) {
                        $git->error($PKG, "commit @{[$commit->commit]} $who $info ($data) matches some negative githooks.checkcommit.$info option");
                        ++$errors;
                    }
                }
            }
        }
    }

    return $errors;
}

sub email_valid_errors {
    my ($git, $commit) = @_;

    my $errors = 0;

    my $cache = $git->cache($PKG);

    if ($git->get_config($CFG => 'email-valid')) {
        # Let's also cache the Email::Valid object
        unless (exists $cache->{email_valid}) {
            $cache->{email_valid} = undef;
            if (eval { require Email::Valid; }) {
                my @checks;
                foreach my $check (qw/mxcheck tldcheck fqdn allow_ip/) {
                    if (my $value = $git->get_config($CFG => "email-valid.$check")) {
                        push @checks, "-$check" => $value;
                    }
                }
                $cache->{email_valid} = Email::Valid->new(@checks);
            } else {
                $git->error($PKG, "the checkcommit.email-valid failed because the Email::Valid Perl module is not installed");
                ++$errors;
            }
        }

        if (my $ev = $cache->{email_valid}) {
            foreach my $who (qw/author committer/) {
                my $who_email = "${who}_email";
                my $email     = $commit->$who_email;
                unless ($ev->address($email)) {
                    my $fail = $ev->details();
                    $git->error($PKG, "commit @{[$commit->commit]} $who email ($email) failed $fail check");
                    ++$errors;
                }
            }
        }
    }

    return $errors;
}

sub _canonical_identity {
    my ($git, $mailmap, $identity) = @_;

    my $cache = $git->cache($PKG);

    unless (exists $cache->{canonical}{$identity}) {
        try {
            my $canonical = $git->run(
                '-c', "mailmap.file=$mailmap",
                'check-mailmap',
                $identity,
            );

            chomp($cache->{canonical}{$identity} = $canonical);
        } otherwise {
            $cache->{canonical}{$identity} = $identity;
            $git->error($PKG, <<'EOS');
The githooks.checkcommit.canonical option requires the git-check-mailmap
command which isn't found. It's available since Git 1.8.4. You should either
upgrade your Git or disable this option.
EOS
        };
    }

    return $cache->{canonical}{$identity};
}

sub canonical_errors {
    my ($git, $commit) = @_;

    my $errors = 0;

    if (my $mailmap = $git->get_config($CFG => 'canonical')) {
        foreach my $who (qw/author committer/) {
            my $who_name  = "${who}_name";
            my $who_email = "${who}_email";
            my $identity  = $commit->$who_name . ' <' . $commit->$who_email . '>';
            my $canonical = _canonical_identity($git, $mailmap, $identity);

            if ($identity ne $canonical) {
                $git->error(
                    $PKG,
                    "commit @{[$commit->commit]} $who identity ($identity) isn't canonical ($canonical)",
                );
                ++$errors;
            }
        }
    }

    return $errors;
}

sub signature_errors {
    my ($git, $commit) = @_;

    my $errors = 0;

    my $signature = $git->get_config($CFG => 'signature');

    if (defined $signature && $signature ne 'nocheck') {
        my $status = $git->run(qw/log -1 --format='%G?'/, $commit->commit);

        if ($status eq 'B') {
            $git->error($PKG, "commit @{[$commit->commit]} has a BAD signature");
            ++$errors;
        } elsif ($signature ne 'optional' && $status eq 'N') {
            $git->error($PKG, "commit @{[$commit->commit]} has NO signature");
            ++$errors;
        } elsif ($signature eq 'trusted' && $status eq 'U') {
            $git->error($PKG, "commit @{[$commit->commit]} has an UNTRUSTED signature");
            ++$errors;
        }
    }

    return $errors;
}

sub code_errors {
    my ($git, $commit, $ref) = @_;

    my $errors = 0;

    state $codes;

    unless (ref $codes) {
        $codes = [];
      CODE:
        foreach my $check ($git->get_config($CFG => 'check-code')) {
            my $code;
            if ($check =~ s/^file://) {
                $code = do $check;
                unless ($code) {
                    if (length $@) {
                        $git->error($PKG, "couldn't parse check-code file ($check): ", $@);
                    } elsif (! defined $code) {
                        $git->error($PKG, "couldn't read check-code file ($check): ", $!);
                    } else {
                        $git->error($PKG, "check-code file ($check) returned FALSE");
                    }
                    ++$errors;
                    next CODE;
                }
            } else {
                $code = eval $check; ## no critic (BuiltinFunctions::ProhibitStringyEval)
                if (length $@) {
                    $git->error($PKG, "couldn't parse check-code value: ", $@);
                    ++$errors;
                    next CODE;
                }
            }
            if (defined $code && ref $code && ref $code eq 'CODE') {
                push @$codes, $code;
            } else {
                $git->error($PKG, "option check-code must end with a code ref");
                ++$errors;
            }
        }
    }

    foreach my $code (@$codes) {
        my $ok = eval { $code->($git, $commit, $ref) };
        if (defined $ok) {
            unless ($ok) {
                $git->error($PKG, "error while evaluating check-code");
                ++$errors;
            }
        } elsif (length $@) {
            $git->error($PKG, 'error while evaluating check-code', $@);
            ++$errors;
        }
    }

    return $errors;
}

sub commit_errors {
    my ($git, $commit, $ref) = @_;

    return
        match_errors($git, $commit) +
        email_valid_errors($git, $commit) +
        canonical_errors($git, $commit) +
        signature_errors($git, $commit) +
        code_errors($git, $commit, $ref);
}

sub check_ref {
    my ($git, $ref) = @_;

    my $errors = 0;

    foreach my $commit ($git->get_affected_ref_commits($ref)) {
        $errors += commit_errors($git, $commit, $ref);
    }

    return $errors;
}

sub check_pre_commit {
    my ($git) = @_;

    _setup_config($git);

    # Construct a fake commit object to pass to the error checking routines.
    my $commit = Git::Repository::Log->new(
        commit    => '<new>',
        author    => "$ENV{GIT_AUTHOR_NAME} <$ENV{GIT_AUTHOR_EMAIL}> 1234567890 -0300",
        committer => "$ENV{GIT_COMMITTER_NAME} <$ENV{GIT_COMMITTER_EMAIL}> 1234567890 -0300",
        message   => "Fake\n",
    );

    return 0 ==
        (match_errors($git, $commit) +
         email_valid_errors($git, $commit) +
         canonical_errors($git, $commit) +
         code_errors($git, $commit));
}

sub check_post_commit {
    my ($git) = @_;

    _setup_config($git);

    my $commit = $git->get_sha1('HEAD');

    if (signature_errors($git, $commit)) {
        $git->error($PKG, "broken commit", <<"EOF");
ATTENTION: To fix the problems in this commit, please consider
amending it:

        git commit --amend      # to amend it
EOF
        return 0;
    } else {
        return 1;
    }

}

# This routine can act both as an update or a pre-receive hook.
sub check_affected_refs {
    my ($git) = @_;

    _setup_config($git);

    return 1 if $git->im_admin();

    my $errors = 0;

    foreach my $ref ($git->get_affected_refs()) {
        $errors += check_ref($git, $ref);
    }

    return $errors == 0;
}

sub check_patchset {
    my ($git, $opts) = @_;

    _setup_config($git);

    return 1 if $git->im_admin();

    my $sha1   = $opts->{'--commit'};
    my $commit = $git->get_commit($sha1);

    return commit_errors($git, $commit) == 0;
}

# Install hooks
PRE_COMMIT       \&check_pre_commit;
POST_COMMIT      \&check_post_commit;
UPDATE           \&check_affected_refs;
PRE_RECEIVE      \&check_affected_refs;
REF_UPDATE       \&check_affected_refs;
PATCHSET_CREATED \&check_patchset;
DRAFT_PUBLISHED  \&check_patchset;

1;


__END__
=for Pod::Coverage match_errors email_valid_errors canonical_errors identity_errors signature_errors spelling_errors pattern_errors subject_errors body_errors footer_errors commit_errors code_errors check_pre_commit check_post_commit check_ref check_affected_refs check_patchset

=head1 NAME

Git::Hooks::CheckCommit - Git::Hooks plugin to enforce commit policies.

=head1 DESCRIPTION

This Git::Hooks plugin hooks itself to the hooks below to enforce
commit policies.

=over

=item * B<pre-commit>

This hook is invoked before a commit is made to check the author and
committer identities.

=item * B<post-commit>

This hook is invoked after a commit is made to check its signature. Note
that the commit is checked after is has been made and any errors must be
fixed with a C<git-commit --amend> command afterwards.

=item * B<update>

This hook is invoked multiple times in the remote repository during C<git
push>, once per branch being updated, to check if all commits being pushed
comply.

=item * B<pre-receive>

This hook is invoked once in the remote repository during C<git push>, to
check if all commits being pushed comply.

=item * B<ref-update>

This hook is invoked when a push request is received by Gerrit Code Review,
to check if all commits being pushed comply.

=item * B<patchset-created>

This hook is invoked when a push request is received by Gerrit Code Review
for a virtual branch (refs/for/*), to check if all commits being pushed
comply.

=back

Projects using Git, probably more than projects using any other version
control system, have a tradition of establishing policies on several aspects
of commits, such as those relating to author and committer identities and
commit signatures.

To enable this plugin you should add it to the githooks.plugin configuration
option:

    git config --add githooks.plugin CheckCommit

=head1 CONFIGURATION

The plugin is configured by the following git options.

=head2 githooks.checkcommit.name [!]REGEXP

This multi-valued option impose restrictions on the valid author and
committer names using regular expressions.

The names must match at least one of the "positive" regular expressions (the
ones not prefixed by "!") and they must not match any one of the negative
regular expressions (the ones prefixed by "!").

This check is performed by the C<pre-commit> local hook.

=head2 githooks.checkcommit.email [!]REGEXP

This multi-valued option impose restrictions on the valid author and
committer emails using regular expressions.

The emails must match at least one of the "positive" regular expressions
(the ones not prefixed by "!") and they must not match any one of the
negative regular expressions (the ones prefixed by "!").

This check is performed by the C<pre-commit> local hook.

=head2 githooks.checkcommit.email-valid [01]

This option uses the L<Email::Valid> module' C<address> method to validade
author and committer email addresses.

These checks are performed by the C<pre-commit> local hook.

Note that the L<Email::Valid> module isn't required to install
L<Git::Hooks>.  If it's not found or if there's an error in the construction
of the C<Email::Valid> object the check fails with a suitable message.

The C<Email::Valid> constructor (new) accepts some parameters. You can pass
the boolean parameters to change their default values by means of the
following sub-options. For more information, please consult the
L<Email::Valid> documentation.

=head3 githooks.checkcommit.email-valid.mxcheck [01]

Specifies whether addresses should be checked for a valid DNS entry. The
default is false.

=head3 githooks.checkcommit.email-valid.tldcheck [01]

Specifies whether addresses should be checked for valid top level
domains. The default is false.

=head3 githooks.checkcommit.email-valid.fqdn [01]

Species whether addresses must contain a fully qualified domain name
(FQDN). The default is true.

=head3 githooks.checkcommit.email-valid.allow_ip [01]

Specifies whether a "domain literal" is acceptable as the domain part.  That
means addresses like: C<rjbs@[1.2.3.4]>. The default is true.

=head2 githooks.checkcommit.canonical MAILMAP

This option requires the use of cannonical names and emails for authors and
committers, as configured in a F<MAILMAP> file and checked by the
C<git-check-mailmap> command. Please, read that command's documentation to
know how to configure a mailmap file for name and email canonicalization.

This check is only able to detect known non-canonical names and emails that
are converted to their canonical forms by the C<git-check-mailmap>
command. This means that if an unknown email is used it won't be considered
an error.

Note that the C<git-check-mailmap> command is available since Git
1.8.4. Older Gits don't have it and Git::Hooks will complain accordingly.

Note that you should not have Git configured to use a default mailmap file,
either by placing one named F<.mailmap> at the top level of the repository
or by setting the configuration options C<mailmap.file> and
C<mailmap.blob>. That's because if Git is configured to use a mailmap it
will convert non-canonical to canonical names and emails before passing them
to the hooks. This will invoke C<git-check-mailmap> using the C<-c> option
to temporarily configure it to use the F<MAILMAP> file.

These checks are performed by the C<pre-commit> local hook.

=head2 githooks.checkcommit.signature {nocheck|optional|good|trusted}

This option allows one to check commit signatures according to these values:

=over

=item * B<nocheck>

By default, or if this value is specified, no check is performed. This value
is useful to disable checks in a repository when they are enabled globally.

=item * B<optional>

This value does not require commits to be signed but if they are their
signatures must be valid (i.e. good or untrusted, but not bad).

=item * B<good>

This value requires that all commits be signed with good signatures.

=item * B<trusted>

This value requires that all commits be signed with good and trusted
signatures.

=back

This check is performed by the C<post-commit> local hook.

=head2 githooks.checkcommit.check-code CODESPEC

If the above checks aren't enough you can use this option to define a custom
code to check your commits. The code may be specified directly as the
option's value or you may specify it indirectly via the filename of a
script. If the option's value starts with "file:", the remaining is treated
as the script filename, which is executed by a B<do> command. Otherwise, the
option's value is executed directly by an eval. Either way, the code must
end with the definition of a routine, which will be called once for each
commit with the following arguments:

=over

=item * B<GIT>

The Git repository object used to grok information about the commit.

=item * B<COMMIT>

This is a hash representing a commit, as returned by the
L<Git::Repository::Plugin::GitHooks::get_commits> method.

=item * B<REF>

The name of the reference being changed, for the B<update> and the
B<pre-receive> hooks. For the B<pre-commit> hook this argument is B<undef>.

=back

The subroutine should return a boolean value indicating success. Any errors
should be produced by invoking the
B<Git::Repository::Plugin::GitHooks::error> method.

If the subroutine returns undef it's considered to have succeeded.

If it raises an exception (e.g., by invoking B<die>) it's considered
to have failed and a proper message is produced to the user.

=cut

=head1 REFERENCES

=over

=item * L<Email::Valid> Module used to check validity of email addresses.

=item * L<A Git Horror Story: Repository Integrity With Signed Commits|http://mikegerwitz.com/papers/git-horror-story>

=back
