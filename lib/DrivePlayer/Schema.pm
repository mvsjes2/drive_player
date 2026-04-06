package DrivePlayer::Schema;

use strict;
use warnings;
use base 'DBIx::Class::Schema';

__PACKAGE__->load_namespaces();

# Connect to a SQLite database at $path, configure pragmas, and deploy
# the schema if the tables do not yet exist.
sub connect_and_deploy {
    my ($class, $path) = @_;

    my $schema = $class->connect(
        "dbi:SQLite:dbname=$path", '', '',
        {
            sqlite_unicode => 1,
            on_connect_do  => [
                'PRAGMA journal_mode=WAL',
                'PRAGMA foreign_keys=ON',
            ],
        },
    );

    # Deploy only when the database is new (tracks table absent)
    my @tables = $schema->storage->dbh->tables(undef, undef, 'tracks', 'TABLE');
    unless (@tables) {
        $schema->deploy({ add_drop_table => 0 });
    }

    return $schema;
}

1;

__END__

=head1 NAME

DrivePlayer::Schema - DBIx::Class schema for the DrivePlayer SQLite database

=head1 DESCRIPTION

A L<DBIx::Class::Schema> subclass that owns the C<scan_folders>, C<folders>,
and C<tracks> result classes.  Use L</connect_and_deploy> rather than the
inherited C<connect> to ensure the SQLite pragmas and tables are set up
correctly.

=head1 METHODS

=head2 connect_and_deploy

  my $schema = DrivePlayer::Schema->connect_and_deploy($path);

Connect to the SQLite database at C<$path>, enable WAL journal mode and
foreign-key enforcement, and deploy the schema (create tables) if the
database is new.  Returns the connected schema object.

=cut
