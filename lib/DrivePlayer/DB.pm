package DrivePlayer::DB;

use DrivePlayer::Setup;
use File::Path       qw( make_path );
use File::Basename   qw( dirname );
use DrivePlayer::Schema;

has path => (
    is       => 'ro',
    isa      => Str,
    required => 1,
);

has schema => (
    is      => 'lazy',
    isa     => InstanceOf['DrivePlayer::Schema'],
    builder => '_build_schema',
);

sub _build_schema {
    my ($self) = @_;
    make_path(dirname($self->path)) unless -d dirname($self->path);
    return DrivePlayer::Schema->connect_and_deploy($self->path);
}

# Trigger schema build (and thus table creation) at construction time.
sub BUILD { $_[0]->schema }

# ---- Helpers ----

# Convert a DBIC Row object to a plain hashref.
sub _row_to_hash { my $row = shift; return $row ? { $row->get_columns() } : undef }

# Return a resultset shorthand.
sub _rs { $_[0]->schema->resultset($_[1]) }

# ---------- scan_folders ----------

sub upsert_scan_folder {
    my ($self, $drive_id, $name) = @_;
    my $row = $self->_rs('ScanFolder')->update_or_create(
        { drive_id => $drive_id, name => $name },
        { key => 'unique_drive_id' },
    );
    return _row_to_hash($row);
}

sub get_scan_folder_by_drive_id {
    my ($self, $drive_id) = @_;
    return _row_to_hash(
        $self->_rs('ScanFolder')->find({ drive_id => $drive_id })
    );
}

sub all_scan_folders {
    my ($self) = @_;
    return map { _row_to_hash($_) }
        $self->_rs('ScanFolder')->search({}, { order_by => 'name' })->all;
}

sub delete_scan_folder {
    my ($self, $drive_id) = @_;
    # cascade_delete on the has_many relationship removes child folders+tracks
    my $row = $self->_rs('ScanFolder')->find({ drive_id => $drive_id });
    $row->delete if $row;
}

# ---------- folders ----------

sub upsert_folder {
    my ($self, %f) = @_;
    my $row = $self->_rs('Folder')->update_or_create(
        {
            drive_id        => $f{drive_id},
            name            => $f{name},
            parent_drive_id => $f{parent_drive_id},
            path            => $f{path},
            scan_folder_id  => $f{scan_folder_id},
        },
        { key => 'unique_drive_id' },
    );
    return _row_to_hash($row);
}

sub get_folder_by_drive_id {
    my ($self, $drive_id) = @_;
    return _row_to_hash(
        $self->_rs('Folder')->find({ drive_id => $drive_id })
    );
}

sub folders_for_scan_folder {
    my ($self, $scan_folder_id) = @_;
    return map { _row_to_hash($_) }
        $self->_rs('Folder')->search(
            { scan_folder_id => $scan_folder_id },
            { order_by       => 'path' },
        )->all;
}

# ---------- tracks ----------

sub upsert_track {
    my ($self, %t) = @_;
    $self->_rs('Track')->update_or_create(
        {
            drive_id      => $t{drive_id},
            title         => $t{title},
            artist        => $t{artist},
            album         => $t{album},
            track_number  => $t{track_number},
            year          => $t{year},
            duration_ms   => $t{duration_ms},
            size          => $t{size},
            mime_type     => $t{mime_type},
            modified_time => $t{modified_time},
            folder_id     => $t{folder_id},
            folder_path   => $t{folder_path},
        },
        { key => 'unique_drive_id' },
    );
}

sub get_track {
    my ($self, $id) = @_;
    return _row_to_hash( $self->_rs('Track')->find($id) );
}

sub get_track_by_drive_id {
    my ($self, $drive_id) = @_;
    return _row_to_hash(
        $self->_rs('Track')->find({ drive_id => $drive_id })
    );
}

my @TRACK_ORDER = (
    \['LOWER(artist) NULLS LAST'],
    \['LOWER(album)  NULLS LAST'],
    \['track_number  NULLS LAST'],
    \['LOWER(title)'],
);

sub all_tracks {
    my ($self) = @_;
    return map { _row_to_hash($_) }
        $self->_rs('Track')->search({}, { order_by => \@TRACK_ORDER })->all;
}

sub tracks_by_artist {
    my ($self, $artist) = @_;
    return map { _row_to_hash($_) }
        $self->_rs('Track')->search(
            \[ 'LOWER(artist) = LOWER(?)', $artist ],
            { order_by => [
                \['LOWER(album)  NULLS LAST'],
                \['track_number  NULLS LAST'],
                \['LOWER(title)'],
            ]},
        )->all;
}

sub tracks_by_album {
    my ($self, $album) = @_;
    return map { _row_to_hash($_) }
        $self->_rs('Track')->search(
            \[ 'LOWER(album) = LOWER(?)', $album ],
            { order_by => [ \['track_number NULLS LAST'], \['LOWER(title)'] ] },
        )->all;
}

sub tracks_by_folder {
    my ($self, $folder_id) = @_;
    return map { _row_to_hash($_) }
        $self->_rs('Track')->search(
            { folder_id => $folder_id },
            { order_by  => [ \['track_number NULLS LAST'], \['LOWER(title)'] ] },
        )->all;
}

sub search_tracks {
    my ($self, $query) = @_;
    my $like = "%$query%";
    return map { _row_to_hash($_) }
        $self->_rs('Track')->search(
            { -or => [
                title  => { like => $like },
                artist => { like => $like },
                album  => { like => $like },
            ]},
            { order_by => \@TRACK_ORDER },
        )->all;
}

sub all_artists {
    my ($self) = @_;
    return $self->_rs('Track')->search(
        { artist => [ -and => { '!=' => undef }, { '!=' => '' } ] },
        { columns  => ['artist'],
          distinct  => 1,
          order_by  => \['LOWER(artist)'] },
    )->get_column('artist')->all;
}

sub all_albums {
    my ($self) = @_;
    return $self->_rs('Track')->search(
        { album => [ -and => { '!=' => undef }, { '!=' => '' } ] },
        { columns  => ['album'],
          distinct  => 1,
          order_by  => \['LOWER(album)'] },
    )->get_column('album')->all;
}

sub top_folders {
    my ($self) = @_;
    return map { _row_to_hash($_) }
        $self->_rs('Folder')->search(
            \[
                'folder.parent_drive_id = scan_folder.drive_id
                 OR folder.drive_id = scan_folder.drive_id'
            ],
            {
                join     => 'scan_folder',
                order_by => 'me.path',
            },
        )->all;
}

sub track_count {
    my ($self) = @_;
    return $self->_rs('Track')->count;
}

sub clear_scan_folder_tracks {
    my ($self, $scan_folder_id) = @_;
    # Collect folder IDs, then bulk-delete tracks and folders.
    # (Relies on foreign_keys=ON cascade for correctness; explicit here for speed.)
    my @folder_ids = $self->_rs('Folder')
        ->search({ scan_folder_id => $scan_folder_id })
        ->get_column('id')->all;

    if (@folder_ids) {
        $self->_rs('Track')->search({ folder_id => \@folder_ids })->delete;
    }
    $self->_rs('Folder')->search({ scan_folder_id => $scan_folder_id })->delete;
}

1;

__END__

=head1 NAME

DrivePlayer::DB - SQLite database facade for the DrivePlayer library

=head1 SYNOPSIS

  use DrivePlayer::DB;

  my $db = DrivePlayer::DB->new(path => '/path/to/music.db');

  # Scan-folder management
  my $sf = $db->upsert_scan_folder($drive_id, 'My Music');
  my @sfs = $db->all_scan_folders;
  $db->delete_scan_folder($drive_id);   # cascades to folders + tracks

  # Track queries
  my @tracks = $db->all_tracks;
  my @tracks = $db->search_tracks('zeppelin');
  my @tracks = $db->tracks_by_artist('Queen');
  my @tracks = $db->tracks_by_album('Led Zeppelin IV');
  my $track  = $db->get_track_by_drive_id($drive_id);
  my $track  = $db->get_track($id);

  my @artists = $db->all_artists;
  my @albums  = $db->all_albums;
  my $count   = $db->track_count;

=head1 DESCRIPTION

A thin L<Moo> facade over a L<DrivePlayer::Schema> (L<DBIx::Class>) schema.
Handles database creation on first use and exposes a simple hashref-based
API so the rest of the application never touches DBIx::Class directly.

All query methods return plain hashrefs (or lists of hashrefs), never
DBIx::Class row objects.

=head1 ATTRIBUTES

=head2 path

  is: ro, isa: Str, required: 1

Filesystem path to the SQLite database file.  The parent directory is
created automatically if it does not exist.

=head2 schema

  is: lazy, isa: DrivePlayer::Schema

The underlying DBIx::Class schema object.  Built automatically on first
access; the database file and tables are created at that point if needed.

=head1 METHODS

=head2 new

  my $db = DrivePlayer::DB->new(path => $path);

Constructor.  The schema (and the SQLite file) is initialised immediately.

=head2 upsert_scan_folder

  my $hashref = $db->upsert_scan_folder($drive_id, $name);

Insert or update a top-level scan folder record.  Returns the row as a
hashref with at least C<id>, C<drive_id>, and C<name>.

=head2 get_scan_folder_by_drive_id

  my $hashref = $db->get_scan_folder_by_drive_id($drive_id);

Returns the scan folder hashref, or C<undef> if not found.

=head2 all_scan_folders

  my @hashrefs = $db->all_scan_folders;

Returns all scan folders ordered alphabetically by name.

=head2 delete_scan_folder

  $db->delete_scan_folder($drive_id);

Deletes the scan folder and, via cascaded foreign-key constraints, all of
its child folders and tracks.

=head2 upsert_folder

  my $hashref = $db->upsert_folder(%fields);

Insert or update a subfolder record.  Required keys: C<drive_id>, C<name>,
C<path>, C<scan_folder_id>.  Optional: C<parent_drive_id>.

=head2 get_folder_by_drive_id

  my $hashref = $db->get_folder_by_drive_id($drive_id);

Returns the folder hashref, or C<undef> if not found.

=head2 folders_for_scan_folder

  my @hashrefs = $db->folders_for_scan_folder($scan_folder_id);

Returns all folders belonging to a scan folder, ordered by path.

=head2 upsert_track

  $db->upsert_track(%fields);

Insert or update a track record keyed on C<drive_id>.  Common fields:
C<drive_id>, C<title>, C<artist>, C<album>, C<track_number>, C<year>,
C<duration_ms>, C<size>, C<mime_type>, C<modified_time>, C<folder_id>,
C<folder_path>.

=head2 get_track

  my $hashref = $db->get_track($id);

Look up a track by its integer primary key.  Returns C<undef> if not found.

=head2 get_track_by_drive_id

  my $hashref = $db->get_track_by_drive_id($drive_id);

Look up a track by its Google Drive file ID.  Returns C<undef> if not found.

=head2 all_tracks

  my @hashrefs = $db->all_tracks;

Returns every track, ordered by artist, album, track_number, title
(all comparisons case-insensitive, NULLs last).

=head2 tracks_by_artist

  my @hashrefs = $db->tracks_by_artist($artist);

Case-insensitive artist match, ordered by album -> track_number -> title.

=head2 tracks_by_album

  my @hashrefs = $db->tracks_by_album($album);

Case-insensitive album match, ordered by track_number -> title.

=head2 tracks_by_folder

  my @hashrefs = $db->tracks_by_folder($folder_id);

All tracks in the given folder, ordered by track_number -> title.

=head2 search_tracks

  my @hashrefs = $db->search_tracks($query);

Case-insensitive substring search across title, artist, and album fields.
Ordered as per L</all_tracks>.

=head2 all_artists

  my @strings = $db->all_artists;

Distinct, non-empty artist names ordered case-insensitively.

=head2 all_albums

  my @strings = $db->all_albums;

Distinct, non-empty album names ordered case-insensitively.

=head2 top_folders

  my @hashrefs = $db->top_folders;

Returns folders that sit at the top level of a scan folder (i.e. whose
parent is the scan-folder root), ordered by path.

=head2 track_count

  my $n = $db->track_count;

Total number of tracks in the database.

=head2 clear_scan_folder_tracks

  $db->clear_scan_folder_tracks($scan_folder_id);

Deletes all tracks and folders belonging to C<$scan_folder_id>.  Used
before a rescan to remove stale data.

=cut
