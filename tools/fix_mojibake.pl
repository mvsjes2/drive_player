#!/usr/bin/env perl

# One-shot repair for rows that were written to the DB before Scanner.pm
# decoded Google::RestApi's UTF-8 byte strings.  Those rows were re-encoded
# by DBIx::Class (sqlite_unicode=1) as if they were Latin-1, producing
# double-encoded mojibake like "Ã\x{96}" where a proper "Ö" should be.
#
# Detection: any string whose bytes round-trip cleanly through
#   decode(UTF-8, encode(latin-1, $s))
# AND where the result differs from the input is assumed double-encoded.
# Strings that are already valid Unicode (no chars in 0080-00FF) are
# skipped.  Strings that fail the latin-1 encode (contain codepoints
# outside 00-FF) are also skipped - those are real Unicode and fine.
#
# Usage:
#   Stop the DrivePlayer app first (WAL + concurrent writes).
#   perl tools/fix_mojibake.pl                        # dry run
#   perl tools/fix_mojibake.pl --apply                # commit changes

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::RealBin/../lib";
use App::DrivePlayer::Config;
use DBI;
use Encode qw( decode encode FB_CROAK LEAVE_SRC );

my $apply = grep { $_ eq '--apply' } @ARGV;
my $path  = App::DrivePlayer::Config->new->db_path;

my $db = DBI->connect(
    "dbi:SQLite:dbname=$path", '', '',
    { RaiseError => 1, sqlite_unicode => 1, AutoCommit => 1 },
);

binmode STDOUT, ':encoding(UTF-8)';

sub try_fix {
    my ($s) = @_;
    return undef unless defined $s && length $s;
    return $s   unless $s =~ /[\x{0080}-\x{00FF}]/;
    # LEAVE_SRC keeps $s intact; without it, encode() with FB_CROAK consumes
    # and truncates its input even on success.
    my $fixed = eval {
        decode('UTF-8',
               encode('latin-1', $s, FB_CROAK | LEAVE_SRC),
               FB_CROAK);
    };
    return $@ ? $s : $fixed;
}

my %targets = (
    tracks       => [qw( title artist album genre comment folder_path )],
    folders      => [qw( name path )],
    scan_folders => [qw( name )],
);

my $total = 0;
for my $table (sort keys %targets) {
    my @cols = @{ $targets{$table} };
    my $rows = $db->selectall_arrayref(
        "SELECT id, " . join(',', @cols) . " FROM $table",
        { Slice => {} },
    );

    for my $r (@$rows) {
        my (%new, @changed);
        for my $c (@cols) {
            my $v     = $r->{$c};
            my $fixed = try_fix($v);
            next if !defined $v || !defined $fixed || $fixed eq $v;
            $new{$c} = $fixed;
            push @changed, $c;
        }
        next unless @changed;

        $total++;
        for my $c (@changed) {
            printf "%s id=%d  %s:  %s  ->  %s\n",
                $table, $r->{id}, $c, $r->{$c}, $new{$c};
        }

        if ($apply) {
            my $set = join(', ', map { "$_ = ?" } @changed);
            $db->do(
                "UPDATE $table SET $set WHERE id = ?",
                undef,
                (map { $new{$_} } @changed),
                $r->{id},
            );
        }
    }
}

print "\n", $total, ' row', ($total == 1 ? '' : 's'),
      ' would be repaired.', "\n" unless $apply;
print "\n", $total, ' row', ($total == 1 ? '' : 's'),
      ' repaired.', "\n" if $apply;
