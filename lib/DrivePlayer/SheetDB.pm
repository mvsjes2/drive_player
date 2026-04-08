package DrivePlayer::SheetDB;

use strict;
use warnings;
use Google::RestApi::SheetsApi4;

# Columns stored in each worksheet.  Tracks only carries metadata fields;
# structural fields (folder_id, duration_ms, etc.) come from Drive scanning.
my @SF_COLS    = qw( drive_id name );
my @TRACK_COLS = qw( drive_id title artist album track_number year genre composer comment );

# ------------------------------------------------------------------
# Constructor
# ------------------------------------------------------------------

sub new {
    my ($class, %args) = @_;
    return bless {
        api            => $args{api},              # Google::RestApi instance
        spreadsheet_id => $args{spreadsheet_id},   # may be undef before create()
    }, $class;
}

sub spreadsheet_id { $_[0]->{spreadsheet_id} }

# ------------------------------------------------------------------
# Connect / Create
# ------------------------------------------------------------------

# Open an existing spreadsheet by ID and ensure both worksheets exist.
sub connect {
    my ($self) = @_;
    my $ss = $self->_sheets_api->open_spreadsheet(id => $self->{spreadsheet_id});
    $self->_ensure_worksheet($ss, 'scan_folders');
    $self->_ensure_worksheet($ss, 'tracks');
    return $ss;
}

# Create a brand-new spreadsheet and return its ID (also stored in $self).
sub create {
    my ($self) = @_;
    my $ss = $self->_sheets_api->create_spreadsheet(title => 'DrivePlayer Library');
    $self->{spreadsheet_id} = $ss->spreadsheet_id();

    # The API creates a default "Sheet1"; rename it to scan_folders.
    my $ws0 = $ss->open_worksheet(id => 0);
    $ws0->rename_worksheet('scan_folders');

    # Add the tracks worksheet.
    $ss->add_worksheet(name => 'tracks');
    $ss->submit_requests();

    return $self->{spreadsheet_id};
}

# ------------------------------------------------------------------
# Push  (SQLite → Sheet)
# ------------------------------------------------------------------

sub push_to_sheet {
    my ($self, $db) = @_;
    my $ss = $self->_open();

    # scan_folders
    my @sf_rows = map { [$_->{drive_id}, $_->{name}] }
                  $db->all_scan_folders();
    $self->_write_worksheet($ss, 'scan_folders', \@SF_COLS, \@sf_rows);

    # tracks (metadata columns only)
    my @track_rows = map { my $t = $_;
                           [map { $t->{$_} // '' } @TRACK_COLS] }
                     $db->all_tracks();
    $self->_write_worksheet($ss, 'tracks', \@TRACK_COLS, \@track_rows);

    return { scan_folders => scalar @sf_rows, tracks => scalar @track_rows };
}

# ------------------------------------------------------------------
# Pull  (Sheet → SQLite)
# ------------------------------------------------------------------

sub pull_from_sheet {
    my ($self, $db) = @_;
    my $ss = $self->_open();

    # scan_folders — upsert all rows
    my $sf_rows    = $self->_read_worksheet($ss, 'scan_folders');
    my $sf_count   = 0;
    for my $row (@$sf_rows) {
        next unless $row->{drive_id} && $row->{name};
        $db->upsert_scan_folder($row->{drive_id}, $row->{name});
        $sf_count++;
    }

    # tracks — only update metadata for tracks already in SQLite
    my $track_rows   = $self->_read_worksheet($ss, 'tracks');
    my $track_count  = 0;
    for my $row (@$track_rows) {
        next unless $row->{drive_id};
        my $track = $db->get_track_by_drive_id($row->{drive_id}) or next;
        $db->update_track_metadata($track->{id},
            map  { $_ => $row->{$_} }
            grep { defined $row->{$_} && $row->{$_} ne '' }
            @TRACK_COLS
        );
        $track_count++;
    }

    return { scan_folders => $sf_count, tracks => $track_count };
}

# ------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------

sub _sheets_api {
    my ($self) = @_;
    return Google::RestApi::SheetsApi4->new(api => $self->{api});
}

sub _open {
    my ($self) = @_;
    die "No spreadsheet_id configured\n" unless $self->{spreadsheet_id};
    return $self->_sheets_api->open_spreadsheet(id => $self->{spreadsheet_id});
}

# Write a header row then all data rows to a named worksheet (full replace).
sub _write_worksheet {
    my ($self, $ss, $name, $cols, $rows) = @_;
    my $ws = $self->_ensure_worksheet($ss, $name);

    $ws->range_all()->clear();

    my @data = ([@$cols], @$rows);
    my $n_rows = scalar @data;
    my $n_cols = scalar @$cols;
    my $end_col = _col_letter($n_cols);

    my $range = $ws->range("A1:${end_col}${n_rows}");
    $range->values(values => \@data);
}

# Read a worksheet, return arrayref of hashrefs keyed by header row.
sub _read_worksheet {
    my ($self, $ss, $name) = @_;
    my $ws = eval { $ss->open_worksheet(name => $name) }
        or return [];

    my $all    = eval { $ws->range_all()->values() }
        or return [];
    return [] unless @$all;

    my @header = @{ shift @$all };
    my @result;
    for my $row (@$all) {
        my %rec;
        for my $i (0 .. $#header) {
            $rec{ $header[$i] } = $row->[$i] // '';
        }
        push @result, \%rec;
    }
    return \@result;
}

# Open a worksheet by name, creating it if absent.
sub _ensure_worksheet {
    my ($self, $ss, $name) = @_;
    my $ws = eval { $ss->open_worksheet(name => $name) };
    return $ws if $ws;
    $ss->add_worksheet(name => $name);
    $ss->submit_requests();
    return $ss->open_worksheet(name => $name);
}

# Convert a 1-based column number to a letter (1→A, 2→B, …, 26→Z).
sub _col_letter {
    my ($n) = @_;
    return chr(64 + $n);   # works for up to 26 columns
}

1;

__END__

=head1 NAME

DrivePlayer::SheetDB - Sync the DrivePlayer library to/from a Google Sheet

=head1 SYNOPSIS

  use DrivePlayer::SheetDB;

  my $sheet = DrivePlayer::SheetDB->new(
      api            => $google_rest_api,   # Google::RestApi instance
      spreadsheet_id => $id,                # undef if creating for first time
  );

  # First time: create the spreadsheet
  my $new_id = $sheet->create();

  # Push local SQLite data to the sheet
  my $counts = $sheet->push_to_sheet($db);   # { scan_folders => N, tracks => N }

  # Pull sheet data into local SQLite
  my $counts = $sheet->pull_from_sheet($db); # { scan_folders => N, tracks => N }

=head1 DESCRIPTION

Uses L<Google::RestApi::SheetsApi4> to maintain a Google Spreadsheet with
two worksheets:

=over 4

=item scan_folders

C<drive_id> and C<name> of each top-level folder that has been added to the
library.  Pulling this on a new device tells it which Drive folders to scan.

=item tracks

Metadata columns only: C<drive_id title artist album track_number year genre
composer comment>.  Structural fields (folder_id, duration_ms, etc.) are
re-derived by scanning Drive on each device.

=back

The local SQLite database (L<DrivePlayer::DB>) remains the working store;
all runtime queries use it.  The Sheet is a portable sync target.

=head1 METHODS

=head2 new(%args)

Required: C<api> (L<Google::RestApi> instance).
Optional: C<spreadsheet_id> (omit when calling C<create()>).

=head2 create()

Creates a new Google Spreadsheet titled "DrivePlayer Library", sets up the
two worksheets, stores and returns the new spreadsheet ID.

=head2 connect()

Opens the existing spreadsheet by C<spreadsheet_id> and ensures the two
worksheets exist.  Dies if the ID is not set or the sheet is not accessible.

=head2 push_to_sheet($db)

Writes all scan folders and track metadata from C<$db> to the sheet,
replacing whatever was there before.  Returns C<{ scan_folders => N, tracks => N }>.

=head2 pull_from_sheet($db)

Reads the sheet and upserts scan folders into C<$db>.  For tracks, only
updates rows that already exist in SQLite (keyed by C<drive_id>); tracks not
yet discovered by a local scan are silently skipped.
Returns C<{ scan_folders => N, tracks => N }>.

=cut
