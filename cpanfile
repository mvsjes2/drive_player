# DrivePlayer CPAN dependencies
# Install with: cpanm --installdeps .

requires 'Google::RestApi';
requires 'DBD::SQLite';
requires 'DBIx::Class';
requires 'Glib';
requires 'Gtk3';
requires 'JSON::MaybeXS';
requires 'Log::Log4perl';
requires 'Moo';
requires 'Readonly';
requires 'ToolSet';
requires 'Type::Tiny';
requires 'YAML::XS';

on test => sub {
    requires 'Mock::MonkeyPatch';
    requires 'Module::Load';
    requires 'Test::Class';
    requires 'Test::Class::Load';
    requires 'Test::Compile';
    requires 'Test::Most';
    requires 'Test::Perl::Critic';
    requires 'Test::Pod';
};
