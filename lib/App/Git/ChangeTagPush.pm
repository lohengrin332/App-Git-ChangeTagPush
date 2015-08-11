package App::Git::ChangeTagPush;

use 5.006;
use strict;
use warnings;

use CPAN::Changes;
use Git::Repository 'Status', 'Log';
use Cwd;
use File::Slurp;
use File::Basename;
use Getopt::Long;
use Pod::Usage;
use POSIX qw(strftime);
use IO::Prompt;
use Try::Tiny;
use Text::Wrap;
use autodie qw(:all);
use version;

=head1 NAME

App::Git::ChangeTagPush

=head1 VERSION

Version 1.0.0

=cut

our $VERSION = '1.0.0';


=head1 SYNOPSIS

This module will add a new version to your Changes file, creating one if necessary.

Basic usage:

    # works just like running `change-tag-push major` from the command line
    use App::Git::ChangeTagPush;
    App::Git::ChangeTagPush->run(
        version_param => 'major',
    );

=head1 SUBROUTINES/METHODS

=head2 run_from_cl

=cut
sub run_from_cl {
    my $self = shift;

    # collect args
    my %config = $self->_process_command_line();

    # run main program
    return $self->run(%config);
}

=head2 run

=cut
sub run {
    my $self = shift;
    my %config = @_;

    # overlay defaults and init other config elements
    %config = $self->_setup_config(%config);

    # load and parse $changes_file
    my $changes = $self->_parse_changes_file(%config);

    # get list of changes since $changes_file
    my @changes_since_changes = $self->_get_list_of_recent_changes(%config);

    # determine version number
    my $version = $self->_determine_version($changes, %config);
    die "Tag $version already exists in repo! You must use a new version.\n"
        if( $config{gitrepo}->run('show-ref', $version) );

    # get/create release entry for this version
    my $release = $self->_get_release_entry($changes, $version, %config);

    # add/replace the release within the $changes_file
    $self->_add_release_to_changes_file($release, $changes, \@changes_since_changes, %config);

    # write out $changes_file, adding a preamble if one doesn't already exist
    $self->_write_changes($changes, $version, %config);

    # show summary of changes
    $self->_summarize_changes(%config);

    # ensure version to be tagged still exists in $changes_file
    $self->_confirm_and_commit_changes($version, %config);

    # push committed changes
    $self->_push_changes($version, %config);

    return 1;
}

=head2 _process_command_line

=cut
sub _process_command_line {
    my $self = shift;

    my %config;
    my $help;

    GetOptions(
        'changes-filename=s' => \$config{changes_filename},
        'preamble=s' => \$config{preamble},
        'help'       => \$help,
    ) || pod2usage(2);

    pod2usage(2) if($help);

    $config{version_param} = shift @ARGV
        or pod2usage( -message => "", -exitval => 2 );

    return %config;
}

=head2 _setup_config

=cut
sub _setup_config {
    my $self = shift;
    my %config = @_;

    # use passed-in gitrepo and changes_filename if they exist
    $config{gitrepo} //= Git::Repository->new(),
    $config{changes_filename} //= 'Changes';

    pod2usage( -message => 'Current repo contains uncommitted changes', -exitval => 2 )
        if( $config{gitrepo}->status('--untracked-files=no') );

    my $changes_dir = $config{gitrepo}->work_tree;
    $config{changes_file} = "$changes_dir/$config{changes_filename}";


    return (
        preamble         => 'Release history for ' . basename(getcwd),
        date             => strftime('%Y-%m-%d', gmtime(time)),
        usage_hint       => 'vN.N.N, vN.N.N.N, or major, minor, patch, trial, or current',
        # default to passed-in values
        %config,
    );
}

=head2 _parse_changes_file

=cut
sub _parse_changes_file {
    my $self = shift;
    my %config = @_;

    write_file($config{changes_file}, '') unless( -s $config{changes_file} );

    return CPAN::Changes->load( $config{changes_file} );
}

=head2 _get_list_of_recent_changes

=cut
sub _get_list_of_recent_changes {
    my $self = shift;
    my %config = @_;

    my ($git_changes_last_log) = Git::Repository->log('-n1', $config{changes_file});
    my @changes_log = ($git_changes_last_log) ? Git::Repository->log($git_changes_last_log->commit . '..') : ();
    return @changes_log;
}

=head2 _determine_version

=cut
sub _determine_version {
    my $self = shift;
    my $changes = shift;
    my %config = @_;

    my $version_spec = $config{version_param};
    my $latest_version = $self->_get_latest_version_in_changes($changes);

    my $new_version = try {
        version->parse($version_spec)
    }
    catch {
        my $err = $_;
        my ($vp1, $vp2, $vp3, $vp4)  = split /\./, $latest_version;
        if    ($version_spec eq 'major') { ++$vp1; $vp2=0; $vp3=0; $vp4=0; }
        elsif ($version_spec eq 'minor') {         ++$vp2; $vp3=0; $vp4=0; }
        elsif ($version_spec eq 'patch') {                 ++$vp3; $vp4=0; }
        elsif ($version_spec eq 'trial') {                         ++$vp4; }
        elsif ($version_spec eq 'current')  { }
        else { die "$version_spec is not a valid version (e.g. $config{usage_hint}): $err\n"; }

        my $v = version->parse( join(".", ($vp4) ? ($vp1, $vp2, $vp3, $vp4) : ($vp1, $vp2, $vp3)) );
        warn "Bumping version from $latest_version to $v\n"
            unless $v eq $latest_version;
        $v;
    };

    $new_version->is_strict
        or die "Version '$version_spec' isn't strictly formated\n";
    $new_version >= $latest_version
        or die "Version $new_version is lower then an existing version ($latest_version)\n";

    return $new_version;
}

=head2 _get_latest_version_in_changes

=cut
sub _get_latest_version_in_changes {
    my $self = shift;
    my $changes_obj = shift;

    my $latest_release = ($changes_obj->releases)[-1]; # undef if none
    my $latest_version = version->parse( ($latest_release) ? $latest_release->version : "v0.0.0" );
    return $latest_version;
}

=head2 _get_release_entry

=cut
sub _get_release_entry {
    my $self = shift;
    my $changes = shift;
    my $version = shift;
    my %config = @_;

    my $release;
    if( $release = $changes->release($version) ) {
        $release->date( $config{date} );
    }
    else {
        $release = CPAN::Changes::Release->new( version => $version, date => $config{date} );
    }

    return $release;
}

=head2 _add_release_to_changes_file

=cut
sub _add_release_to_changes_file {
    my $self = shift;
    my $release = shift;
    my $changes = shift;
    my @changes_since_changes = @{ shift @_ };
    my %config = @_;

    # add the changes to the release object
    $release->add_changes( map {
        sprintf "%.7s: %s", $_->commit, $_->subject
    } @changes_since_changes );

    # add/replace the release within the changes
    $changes->add_release($release);
}

=head2 _write_changes

=cut
sub _write_changes {
    my $self = shift;
    my $changes = shift;
    my $version = shift;
    my %config = @_;

    $changes->preamble($config{preamble}) unless( $changes->preamble );
    local($Text::Wrap::columns) = 132; ## no critic (ProhibitPackageVars) - the default of 76 is way too low
    write_file( $config{changes_file}, $changes->serialize );
    warn "Raw commit log for $version added to $config{changes_file}\n";
}

=head2 _summarize_changes

=cut
sub _summarize_changes {
    my $self = shift;
    my %config = @_;

    my $EDITOR = $ENV{EDITOR} || 'vi';
    system("$EDITOR $config{changes_file}") if( $self->_prompt('Summarize for human readability?') );

    system("git diff --ignore-all-space $config{changes_file}") if( $self->_prompt('Review git diff?') );
}

=head2 _prompt

=cut
sub _prompt {
    my $self = shift;
    my $message = shift;

    my $user_response = prompt($message . ' ([Y]/n): ');

    return ($user_response =~ m/^no?/i)? 0 : 1;
}

=head2 _confirm_and_commit_changes

=cut
sub _confirm_and_commit_changes {
    my $self = shift;
    my $version = shift;
    my %config = @_;

    CPAN::Changes->load($config{changes_file})->release($version)
        or die "Error: $config{changes_file} no longer contains an entry for $version!\n";

    if( $self->_prompt("Commit $config{changes_file} and tag current tree as $version?") ) {
        $config{gitrepo}->run('add', $config{changes_file});
        $config{gitrepo}->run('commit', "--message='Updated Changes for $version'", $config{changes_file});
        $config{gitrepo}->run('tag', '-a', '--message=', $version);
    }
    else {
        die "Abort!\n";
    }
}

=head2 _push_changes

=cut
sub _push_changes {
    my $self = shift;
    my $version = shift;
    my %config = @_;

    my $branch_name = $config{gitrepo}->run('rev-parse', '--abbrev-ref', 'HEAD');
    $config{gitrepo}->run('push', '--follow-tags') if( $self->_prompt("Push $version and the $branch_name branch to origin?") );
}

=head1 AUTHORS

Tim Bunce, C<< <tim.bunce at pobox.com> >>
JD Lewis, C<< <jdavidlewis at jdlmx.com> >>

=head1 BUGS

Please report any bugs or feature requests through the web interface at L<https://github.com/lohengrin332/App-Git-ChangeTagPush/issues>.
We will be notified, and then you'll automatically be notified of progress on your bug as we make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc App::Git::ChangeTagPush


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=App-Git-ChangeTagPush>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/App-Git-ChangeTagPush>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/App-Git-ChangeTagPush>

=item * Search CPAN

L<http://search.cpan.org/dist/App-Git-ChangeTagPush/>

=back


=head1 ACKNOWLEDGEMENTS


=head1 LICENSE AND COPYRIGHT

Copyright 2015 Tim Bunce.

This program is free software; you can redistribute it and/or modify it
under the terms of the the Artistic License (2.0). You may obtain a
copy of the full license at:

L<http://www.perlfoundation.org/artistic_license_2_0>

Any use, modification, and distribution of the Standard or Modified
Versions is governed by this Artistic License. By using, modifying or
distributing the Package, you accept this license. Do not use, modify,
or distribute the Package, if you do not accept this license.

If your Modified Version has been derived from a Modified Version made
by someone other than you, you are nevertheless required to ensure that
your Modified Version complies with the requirements of this license.

This license does not grant you the right to use any trademark, service
mark, tradename, or logo of the Copyright Holder.

This license includes the non-exclusive, worldwide, free-of-charge
patent license to make, have made, use, offer to sell, sell, import and
otherwise transfer the Package with respect to any patent claims
licensable by the Copyright Holder that are necessarily infringed by the
Package. If you institute patent litigation (including a cross-claim or
counterclaim) against any party alleging that the Package constitutes
direct or contributory patent infringement, then this Artistic License
to you shall terminate on the date that such litigation is filed.

Disclaimer of Warranty: THE PACKAGE IS PROVIDED BY THE COPYRIGHT HOLDER
AND CONTRIBUTORS "AS IS' AND WITHOUT ANY EXPRESS OR IMPLIED WARRANTIES.
THE IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE, OR NON-INFRINGEMENT ARE DISCLAIMED TO THE EXTENT PERMITTED BY
YOUR LOCAL LAW. UNLESS REQUIRED BY LAW, NO COPYRIGHT HOLDER OR
CONTRIBUTOR WILL BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, OR
CONSEQUENTIAL DAMAGES ARISING IN ANY WAY OUT OF THE USE OF THE PACKAGE,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


=cut

1; # End of App::Git::ChangeTagPush
