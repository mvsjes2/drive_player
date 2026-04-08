package DrivePlayer::SheetDB;

use strict;
use warnings;
use Google::RestApi::SheetsApi4;

# Columns for the scan_folders index worksheet.
my @SF_COLS = qw( drive_id name );

# Metadata columns written to each per-folder worksheet.
my @TRACK_COLS = qw( drive_id title artist album track_number year genre composer comment );

# ------------------------------------------------------------------
# Constructor
# ------------------------------------------------------------------

sub new {
    my ($class, %args) = @_;
    return bless {
        api            => $args{api},              # Google::RestApi instance
        spreadsheet_id => $args{spreadsheet_id},   # undef before create()
    }, $class;
}

sub spreadsheet_id { $_[0]->{spreadsheet_id} }

# ------------------------------------------------------------------
# Create
# ------------------------------------------------------------------

# Create a new spreadsheet and return its ID (also stored in $self).
# The default "Sheet1" is renamed to "scan_folders"; folder worksheets
# are created on first push.
sub create {
    my ($self) = @_;
    my $ss = $self->_sheets_api->create_spreadsheet(title => 'DrivePlayer Library');
    $self->{spreadsheet_id} = $ss->spreadsheet_id();

    my $ws0 = $ss->open_worksheet(id => 0);
    $ws0->ws_rename('scan_folders');
    $ss->submit_requests();

    return $self->{spreadsheet_id};
}

# ------------------------------------------------------------------
# Push  (SQLite → Sheet)
# ------------------------------------------------------------------

# Write all scan folders and their tracks to the spreadsheet.
# Each scan folder gets its own worksheet named after the folder.
# Returns { scan_folders => N, tracks => N }.
sub push_to_sheet {
    my ($self, $db) = @_;
    my $ss = $self->_open();

    my @scan_folders = $db->all_scan_folders();

    # Write the scan_folders index tab
    my @sf_rows = map { [$_->{drive_id}, $_->{name}] } @scan_folders;
    $self->_write_worksheet($ss, 'scan_folders', \@SF_COLS, \@sf_rows);

    # Write one worksheet per scan folder
    my $total_tracks = 0;
    for my $sf (@scan_folders) {
        my @tracks     = $db->tracks_by_scan_folder($sf->{id});
        my @track_rows = map { my $t = $_;
                               [map { $t->{$_} // '' } @TRACK_COLS] } @tracks;
        $self->_write_worksheet($ss, _ws_name($sf->{name}), \@TRACK_COLS, \@track_rows);
        $total_tracks += scalar @tracks;
    }

    return { scan_folders => scalar @scan_folders, tracks => $total_tracks };
}

# ------------------------------------------------------------------
# Pull  (Sheet → SQLite)
# ------------------------------------------------------------------

# Read the spreadsheet and apply it to the local SQLite DB.
# Scan folders are upserted; track metadata is only applied to tracks
# that already exist in SQLite (i.e. have been scanned locally).
# Returns { scan_folders => N, tracks => N }.
sub pull_from_sheet {
    my ($self, $db) = @_;
    my $ss = $self->_open();

    # Pull scan_folders index
    my $sf_rows  = $self->_read_worksheet($ss, 'scan_folders');
    my $sf_count = 0;
    for my $row (@$sf_rows) {
        next unless $row->{drive_id} && $row->{name};
        $db->upsert_scan_folder($row->{drive_id}, $row->{name});
        $sf_count++;
    }

    # Pull tracks from each folder worksheet
    my $track_count = 0;
    for my $sf_row (@$sf_rows) {
        next unless $sf_row->{name};
        my $rows = $self->_read_worksheet($ss, _ws_name($sf_row->{name}));
        for my $row (@$rows) {
            next unless $row->{drive_id};
            my $track = $db->get_track_by_drive_id($row->{drive_id}) or next;
            $db->update_track_metadata($track->{id},
                map  { $_ => $row->{$_} }
                grep { defined $row->{$_} && $row->{$_} ne '' }
                @TRACK_COLS
            );
            $track_count++;
        }
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

    my @data    = ([@$cols], @$rows);
    my $n_rows  = scalar @data;
    my $end_col = _col_letter(scalar @$cols);
    $ws->range("A1:${end_col}${n_rows}")->values(values => \@data);
}

# Read a worksheet and return arrayref of hashrefs keyed by header row.
# Returns [] if the worksheet doesn't exist or is empty.
sub _read_worksheet {
    my ($self, $ss, $name) = @_;
    my $ws = eval { $ss->open_worksheet(name => $name) } or return [];

    my $all = eval { $ws->range_all()->values() } or return [];
    return [] unless @$all;

    my @header = @{ shift @$all };
    my @result;
    for my $row (@$all) {
        my %rec;
        $rec{ $header[$_] } = $row->[$_] // '' for 0 .. $#header;
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

# Sanitise a folder name for use as a worksheet tab name.
# Google Sheets forbids [ ] * / \ ? : and limits names to 100 chars.
sub _ws_name {
    my ($name) = @_;
    $name =~ s{[\[\]*\/\\?:]}{}g;
    $name =~ s/^\s+|\s+$//g;
    $name = 'Folder' unless length $name;
    return substr($name, 0, 100);
}

# Convert a 1-based column number to a letter (1→A … 26→Z).
sub _col_letter {
    my ($n) = @_;
    return chr(64 + $n);
}

1;

__END__

=head1 NAME

DrivePlayer::SheetDB - Sync the DrivePlayer library to/from a Google Sheet

=head1 SYNOPSIS

  use DrivePlayer::SheetDB;

  my $sheet = DrivePlayer::SheetDB->new(
      api            => $google_rest_api,
      spreadsheet_id => $id,             # omit when calling create()
  );

  my $id     = $sheet->create();             # create spreadsheet, returns ID
  my $counts = $sheet->push_to_sheet($db);  # { scan_folders => N, tracks => N }
  my $counts = $sheet->pull_from_sheet($db);

=head1 DESCRIPTION

Maintains a Google Spreadsheet with one worksheet per scan folder, plus a
C<scan_folders> index tab:

=over 4

=item scan_folders

C<drive_id> and C<name> for every top-level folder in the library.

=item One tab per folder (named after the folder)

Track metadata columns: C<drive_id title artist album track_number year
genre composer comment>.  Structural fields (folder_id, duration_ms, etc.)
are re-derived from Drive scanning and are not stored in the sheet.

=back

The local SQLite database remains the working store for all runtime queries.
The Sheet is a portable sync target accessible from any device with Drive access.

=head1 NEW DEVICE WORKFLOW

  1. File -> Sync from Sheet   # pulls scan_folders into SQLite
  2. Library -> Scan           # discovers audio files on Drive
  3. File -> Sync from Sheet   # applies saved metadata to the scanned tracks

=head1 METHODS

=head2 new(%args)

C<api> (L<Google::RestApi> instance) is required.
C<spreadsheet_id> is optional (omit before calling C<create()>).

=head2 create()

Creates a new "DrivePlayer Library" spreadsheet with a C<scan_folders> tab.
Returns and stores the new spreadsheet ID.

=head2 push_to_sheet($db)

Writes the C<scan_folders> index and one worksheet of track metadata per
folder, replacing whatever was there before.

=head2 pull_from_sheet($db)

Upserts scan folders into SQLite and applies track metadata to any tracks
already present (keyed by C<drive_id>).  Tracks not yet scanned locally
are silently skipped.

=cut
