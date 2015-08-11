#!perl -T
use 5.006;
use strict;
use warnings;
use Test::More;

plan tests => 1;

BEGIN {
    use_ok( 'App::Git::ChangeTagPush' ) || print "Bail out!\n";
}

diag( "Testing App::Git::ChangeTagPush $App::Git::ChangeTagPush::VERSION, Perl $], $^X" );
