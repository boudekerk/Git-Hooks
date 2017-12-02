#!/usr/bin/env perl

package Git::Hooks::Notify;
# ABSTRACT: Git::Hooks plugin to notify users via email

use 5.010;
use utf8;
use strict;
use warnings;
use Carp;
use Git::Hooks;
use Git::Repository::Log;
use Set::Scalar;
use List::MoreUtils qw/any/;
use Try::Tiny;

my $PKG = __PACKAGE__;
(my $CFG = __PACKAGE__) =~ s/.*::/githooks./;

sub pretty_log {
    my ($git, $branch, $options, $paths, $max_count, $commits) = @_;

    my $log = "Branch: $branch\n";

    my $commit_url = $git->get_config($CFG, 'commit-url') || '%H';

    my $replace_commit = sub {
        my ($sha1) = @_;
        my $pattern = $commit_url;
        $pattern =~ s/%H/$sha1/e;
        return $pattern;
    };

    foreach my $commit (@$commits) {
        $log .= <<EOF;

commit @{[$replace_commit->($commit->commit)]}
Author: @{[$commit->author]}
Date:   @{[scalar(localtime($commit->author_localtime))]}

@{[$commit->raw_message]}@{[$commit->extra]}
EOF
    }

    return $log;
}

sub get_transport {
    my ($git) = @_;

    my $transport = $git->get_config($CFG, 'transport');

    return unless $transport;

    my @args = split / /, $transport;

    $transport = shift @args;

    my %args;

    foreach (@args) {
        my ($arg, $value) = split /=/;
        $args{$arg} = $value;
    }

    eval "require Email::Sender::Transport::$transport";

    return "Email::Sender::Transport::$transport"->new(\%args);
}

sub notify {
    my ($git, $recipients, $body) = @_;

    return 1 unless @$recipients;

    my @headers = (
        'Subject' => $git->get_config($CFG => 'subject') || '[Git::Hooks::Notify]',
        'To'      => join(', ', @$recipients),
    );

    if (my $from = $git->get_config($CFG, 'from')) {
        push @headers, (From => $from);
    }

    require Email::Sender::Simple;
    require Email::Simple;

    my $preamble = $git->get_config($CFG, 'preamble') || <<'EOF';
You're receiving this automatic notification because commits were pushed to a
Git repository you're watching.
EOF
    chomp $preamble;

    my $email = Email::Simple->create(
        header => \@headers,
        body   => "$preamble\n\n$body",
    );

    return Email::Sender::Simple->send(
        $email,
        {transport => get_transport($git) || Email::Sender::Simple->default_transport()},
    );
}

sub grok_rules {
    my ($git) = @_;

    my @text_rules = $git->get_config($CFG, 'rule');

    my @rules;
    foreach my $rule (@text_rules) {
        my ($recipients, $paths) = split /\s*--\s*/, $rule;

        push @rules, {
            recipients => [split / /, $recipients],
            paths      => [defined $paths ? split / /, $paths : ()],
        };
    }

    return @rules;
}

# This routine can act as a post-receive hook.
sub notify_affected_refs {
    my ($git) = @_;

    my @branches = grep {m:^refs/heads/:} $git->get_affected_refs();

    return 1 unless @branches;

    my @rules = grok_rules($git);

    return 1 unless @rules;

    my $max_count = $git->get_config($CFG, 'max-count') || '10';

    my @options = ('--numstat', '--first-parent', "--max-count=$max_count");

    my $errors = 0;

    foreach my $branch (@branches) {
        foreach my $rule (@rules) {
            my @commits = $git->get_affected_ref_commits($branch, \@options, $rule->{paths});

            next unless @commits;

            my $message = pretty_log($git, $branch, \@options, $rule->{paths}, $max_count, \@commits);

            try {
                notify($git, $rule->{recipients}, $message);
            } catch {
                my $error = $_;
                $git->error($PKG, 'Could not send mail to the following recipients: '
                                . join(", ", $error->recipients) . "\n"
                                . 'Error message: ' . $error->message . "\n"
                            );
                ++$errors;
            };
        }
    }

    return $errors == 0;
}

# Install hooks
POST_RECEIVE \&notify_affected_refs;

1;


__END__
=for Pod::Coverage get_transport grok_include_rules notify notify_affected_refs ref_changes

=head1 NAME

Notify - Git::Hooks plugin to notify users via email

=head1 DESCRIPTION

This L<Git::Hooks> plugin hooks itself to the hooks below to notify users via
email about pushed commits affecting specific files in the repository.

=over

=item * B<post-receive>

This hook is invoked once in the remote repository after a successful C<git
push>. It's used to notify JIRA of commits citing its issues via comments.

=back

To enable it you should add it to the githooks.plugin configuration
option:

    git config --add githooks.plugin Notify

The email notification is sent in text mode with configurable C<Subject> and
C<From> headers. The body of the message contains a section for each branch
affected by the git-push command. Each section contains the result of a C<git
log> command showing the pushed commits and the list of files affected by
them. For example:

  Subject: [Git::Hooks::Notify]

  You're receiving this automatic notification because commits were pushed to a
  Git repository you're watching.

  Branch: refs/heads/master

  commit 6eaa6a84fbd7e2a64e66664f3d58707618e20c72
  Author: Gustavo L. de M. Chaves <gnustavo@cpan.org>
  Date:   Mon Dec 4 21:41:19 2017 -0200

      Add plugin Git::Hooks::Notify

  305     0       lib/Git/Hooks/Notify.pm
  63      0       t/02-notify.t

  commit b0a820600bb093afeafa547cbf39c468380e41af (tag: v2.1.8, origin/next, next)
  Author: Gustavo L. de M. Chaves <gnustavo@cpan.org>
  Date:   Sat Nov 25 21:34:48 2017 -0200

      v2.1.8

  9       0       Changes

  commit c45feb16fe3e6fc105414e60e91ffb031c134cd4
  Author: Gustavo L. de M. Chaves <gnustavo@cpan.org>
  Date:   Sat Nov 25 19:13:42 2017 -0200

      CheckJira: JQL options are scalar, not multi-valued

  40      32      lib/Git/Hooks/CheckJira.pm
  12      12      t/02-check-jira.t

You can change the C<git log> format and a few other things in the message using
the configuration options explained below.

=head1 CONFIGURATION

The plugin is configured by the following git options.

=head2 githooks.notify.transport TRANSPORT [ARGS...]

By default the messages are sent using L<Email::Simple>'s default transport. On
Unix systems, it is usually the C<sendmail> command. You can specify another
transport using this configuration.

C<TRANSPORT> must be the basename of an available transport class, such as
C<SMTP>, C<Maildir>, or C<Mbox>. The name is prefixed with
C<Email::Sender::Transport::> and the complete name is required like this:

  eval "require Email::Sender::Transport::$TRANSPORT";

So, you must make sure such a transport is installed in your server's Perl.

C<ARGS> is a space-separated list of C<VAR=VALUE> pairs. All pairs will be
tucked in a hash and passed to the transport's constructor. For example:

  [githooks "notify"]
    transport = SMTP host=smtp.example.net ssl=starttls sasl_username=myself sasl_password=myword
    transport = Mbox filename=/home/user/.mbox
    transport = Maildir dir=/home/user/maildir

Please, read the transport's class documentation to know which arguments are
available.

=head2 githooks.notify.rule RECIPIENTS [-- PATHS]

The B<rule> directive adds a notification rule specifying which RECIPIENTS
should be notified of pushed commits affecting the specified PATHS.

If no path is specified, the recipients are notified about every push.

C<RECIPIENTS> is a space-separated list of email addresses.

C<PATHS> is a space-separated list of pathspecs, used to restrict notifications
to commits affecting particular paths in the repository. Note that the list of
paths starts after a double-dash (--). Please, read about pathspecs in the C<git
help glossary>.

=head2 githooks.notify.from SENDER

This allows you to specify a sender address to be used in the notification's
C<To> header. If you don't specify it, the sender will probably be the user
running your hooks. But you shouldn't count on it. It's better to specify it
with a valid email address that your users can reply to. Something like this:

  [githooks "notify"]
    from = "Git::Hooks" <git@yourdomain.com>

=head2 githooks.notify.subject SUBJECT

This allows you to specify the subject of the notification emails. If you don't
specify it, the default is like this:

  Subject: [Git::Hooks::Notify]

=head2 githooks.notify.preamble TEXT

This allows you to specify a preamble for the notification emails. If you don't
specify it, the default is like this:

  You're receiving this automatic notification because commits were pushed to a
  Git repository you're watching.

=head2 githooks.notify.max-count NUM

This allows you to specify the limit of commits that should be shown for each
changed branch. Read about the --max-count option in C<git help log>. If not
specified, a limit of 10 is used.

=head2 githooks.notify.commit-url URL_PATTERN

If your Git repository has a web interface it's useful to provide links to the
commits shown in the notification message. If configured, each SHA1 contained in
the C<git-log> output is substituted by C<URL_PATTERN>, with the C<%H>
placeholder replaced by the SHA1.

See below how to configure this for some common Git servers. Replace the
angle-bracketed names with values appropriate to your context:

=over

=item * GitHub

  https://github.com/<USER>/<REPO>/commit/%H

=item * Bitbucket Cloud

  https://bitbucket.org/<USER>/<REPO>/commits/%H

=item * Bitbucket Server

  <BITBUCKET_BASE_URL>/projects/<PROJECTID>/repos/<REPOID>/commits/%H

=item * Gerrit with Gitblit

  <GERRIT_BASE_URL>/plugins/gitblit/commit/?r=<REPO>&h=%H

=back

=head1 TO DO

These are just a few of the ideas for improving this plugin.

=over

=item * Send well-formatted HTML messages.

=item * Generalize the C<commit-url> template.

It should support other placeholders for the Git server's base URL, repository
name, user name, etc. So that we could configure a single template for all
repositories in a server. Currently one has to configure a different commit-url
for each repository.

=item * Send notifications on Gerrit's change-merged hook.

=back

=head1 SEE ALSO

=over

=item * L<Email::Sender::Simple>

=item * L<Email::Sender::Transport::SMTP>

=back
