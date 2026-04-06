use strict;
use warnings;

use FindBin;
use lib "$FindBin::RealBin/../lib";
use lib "$FindBin::RealBin/../../../p5-google-restapi/lib";
use File::Find;
use Test::More;

# Modules that require system libraries not available in all test environments.
my %skip = map { $_ => 1 } qw(
    DrivePlayer::GUI
);

my @modules;
my $lib = "$FindBin::RealBin/../lib";
find(
    sub {
        return unless /\.pm$/;
        my $module = $File::Find::name;
        $module =~ s{^\Q$lib\E/}{};
        $module =~ s{/}{::}g;
        $module =~ s{\.pm$}{};
        push @modules, $module;
    },
    $lib,
);

my @testable = grep { !$skip{$_} } sort @modules;
plan tests => scalar @testable;

for my $module (@testable) {
    use_ok($module);
}
