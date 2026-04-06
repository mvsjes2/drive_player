use strict;
use warnings;

use FindBin;
use lib "$FindBin::RealBin/../lib";
use lib "$FindBin::RealBin/../../../p5-google-restapi/lib";
use File::Find;
use Test::More;

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

my @sorted = sort @modules;
plan tests => scalar @sorted;

for my $module (@sorted) {
    use_ok($module);
}
