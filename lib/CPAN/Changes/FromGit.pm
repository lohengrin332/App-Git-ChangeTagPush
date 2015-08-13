package CPAN::Changes::FromGit;

use Moo;

use version;
use autodie;
use Carp;
use File::Basename;
use POSIX qw(strftime);
use Try::Tiny;
use Text::Wrap;
use Scalar::Util qw(blessed);

use CPAN::Changes 0.400001;
use Git::Repository 'Log';


our $VERSION = '1.01';

has changes_file => (
    is => 'ro',
    lazy => 1,
    default => sub {
        my $work_tree = shift->gitrepo->work_tree;
        return "$work_tree/Changes"; # XXX add changes_file_basename?
    },
);

has changes => (
    is => 'lazy',
    clearer => 1,
    default => sub {
        my $self = shift;
        my $changes_file = $self->changes_file;
        # create empty file to bootstrap if need be
        open my $fh, ">", $changes_file unless -f $changes_file;
        return CPAN::Changes->load( $changes_file, next_token => $self->next_token_qr )
    },
);

has gitrepo => (
    is => 'lazy',
    default => sub {
        my $self = shift;
        return Git::Repository->new(); # finds work_tree from current dir
    },
);

has preamble => (
    is => 'rw',
);

# see https://metacpan.org/pod/CPAN::Changes#DEALING-WITH-NEXT-VERSION-PLACEHOLDERS
has next_token_string => (
    is => 'rw',
    default => '{{$NEXT}}',
);

has changes_wrap_columns => (
    is => 'rw',
    default => 132,
);


sub write_changes_file {
    my $self = shift;

    local($Text::Wrap::columns) = $self->changes_wrap_columns; ## no critic (ProhibitPackageVars) - the default of 76 is way too low

    # we preserve the existing preamble if there is one
    # otherwise we apply ours or else a simple default
    if (not $self->changes->preamble) {
        my $preamble = $self->preamble
            || sprintf "Release history for %s\n\n", basename(dirname($self->changes_file));
        $self->changes->preamble($preamble);
    }

    open my $fh, ">", $self->changes_file;
    print $fh $self->changes->serialize;
    close $fh;

    return 1;
}


sub get_recent_git_change_log {
    my ($self, $since) = @_;

    # $since can be ref known to git or a Git::Repository::Log object
    # defaults to the last change to the Changes file
    $since ||= ($self->gitrepo->log('-n1', $self->changes_file))[0];
    $since = $since->commit if $since && blessed($since) && $since->can('commit');

    my @changes_log = ($since) ? $self->gitrepo->log($since . '..') : ();
    return @changes_log; # returns count in scalar context
}


sub get_latest_version_in_changes {
    my $self = shift;

    # get latest release version that isn't next_token_string
    my $latest_release;
    for my $idx (-1, -2) {
        $latest_release = ($self->changes->releases)[$idx]
            or return undef;
        last if $latest_release->version eq $self->next_token_string;
    }
    my $version = $latest_release->version; # might be next_token_string
    return eval { version->parse( $version ) } || $version;
}


sub get_next_version {
    my ($self, $version_spec) = @_;

    return $self->next_token_string
        if $version_spec eq 'next';

    my $latest_version = $self->get_latest_version_in_changes
        || version->parse('v0.0.0');

    my $new_version = increment_version($latest_version, $version_spec);

    $new_version >= $latest_version
        or die "Version $new_version is lower than the latest existing version $latest_version\n";

    return $new_version;
}


sub increment_version { # support function, not a method
    my ($current_version, $version_spec) = @_;

    my $new_version = try {
        version->parse($version_spec)
    }
    catch {
        my $err = $_;
        my ($vp1, $vp2, $vp3)  = split /\./, $current_version;
        if    ($version_spec eq 'major') { ++$vp1; $vp2=0; $vp3=0; }
        elsif ($version_spec eq 'minor') {         ++$vp2; $vp3=0; }
        elsif ($version_spec eq 'patch') {                 ++$vp3; }
        elsif ($version_spec eq 'current')  { }
        else { die "Version specifier '$version_spec' is not valid (e.g. vN.N.N, major, minor, patch, or current): $err\n"; }

        my $v = version->parse( join(".", $vp1, $vp2, $vp3) );
        #warn "Bumping version from $current_version to $v\n" unless $v eq $current_version;
        $v;
    };

    $new_version->is_strict
        or die "Version '$version_spec' isn't strictly formated\n";

    return $new_version;
}


sub get_release_entry_for_version {
    my $self = shift;
    my $version = shift;
    my $set_date = shift; # false, a new date string, a strftime template or "1" to use '%Y-%m-%d'

    if ("$version" eq $self->next_token_string) {
        my $latest = ($self->changes->releases)[-1];
        return $latest if $latest && $latest->version eq $self->next_token_string;
        return CPAN::Changes::Release->new( version => $self->next_token_string );
    }

    my $latest_version = $self->get_latest_version_in_changes;

    my $release = $self->changes->release($version);

    unless ($release) {
        if ( $version > $latest_version) {
            $release = CPAN::Changes::Release->new( version => $version );
        }
        else {
            croak sprintf "No %s release in %s (latest is %s)",
                $version, $self->changes_file, $latest_version;
        }
    }

    if ($set_date) {
        croak "Can't alter date of non-latest version $version (latest is $latest_version)"
            if $version < $latest_version;
        $set_date = '%Y-%m-%d' if $set_date eq "1";
        $set_date = strftime($set_date, gmtime(time)) if $set_date =~ m/%/;
        $release->date( $set_date );
    }

    return $release;
}


sub add_changes {
    my ($self, $version_spec, $log_formatter, $since, $set_date) = @_;

    my $new_version = $self->get_next_version($version_spec);

    my $release = $self->get_release_entry_for_version($new_version, $set_date // 1);

    my @changelogs = $self->get_recent_git_change_log($since);

    $log_formatter ||= sub { return sprintf "%s - %.7s", $_->subject, $_->commit };

    $release->add_changes( map { $log_formatter->($_) } @changelogs );

    $self->changes->add_release($release);

    # we don't write_changes_file here so caller can run extra checks
    # such as checking there's no tag called $new_version already,
    # before they call write_changes_file

    return $new_version;
}


sub commit_changes_and_tag_with_version {
    my ($self, $version) = @_;

    # typically called soon after add_changes

    $version ||= $self->get_latest_version_in_changes
        || croak "No version in ".$self->changes_file;

    my $is_next_token = ("$version" eq $self->next_token_string);

    my $message = sprintf "Updated %s for %s",
        basename($self->changes_file),
        ($is_next_token) ? 'next version' : $version;

    $self->gitrepo->run("commit", "--message=$message", $self->changes_file);

    $self->gitrepo->run("tag", "-a", "--message=", $version)
        unless $is_next_token;

    return 1;
}


sub next_token_qr {
    my $next_token_string = shift->next_token_string;
    return qr/\Q$next_token_string\E/x;
}


1;
