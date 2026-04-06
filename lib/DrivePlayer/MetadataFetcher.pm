package DrivePlayer::MetadataFetcher;

use strict;
use warnings;
use HTTP::Tiny;
use JSON::PP     qw( decode_json );
use URI::Escape  qw( uri_escape );
use Time::HiRes  qw( sleep time );

my $MB_BASE    = 'https://musicbrainz.org/ws/2';
my $USER_AGENT = 'DrivePlayer/1.0 (https://github.com/mvsjes2/drive_player)';
my $MIN_GAP    = 1.1;   # MusicBrainz rate limit: 1 req/sec

my $last_req_time = 0;

sub new { return bless {}, shift }

sub fetch {
    my ($self, %args) = @_;

    my $title  = $args{title}  or return;
    my $artist = $args{artist} // '';
    my $album  = $args{album}  // '';

    my $query = 'recording:"' . _mb_escape($title) . '"';
    $query   .= ' AND artist:"'  . _mb_escape($artist) . '"' if $artist;
    $query   .= ' AND release:"' . _mb_escape($album)  . '"' if $album;

    my $url = "$MB_BASE/recording?query=" . uri_escape($query)
            . '&fmt=json&limit=5&inc=releases+artist-credits+tags';

    my $data = $self->_get($url) or return;
    my $recs = $data->{recordings} or return;
    return unless @$recs;

    return _parse($recs->[0]);
}

# ---------- private ----------

sub _parse {
    my ($rec) = @_;
    my %meta;

    $meta{title} = $rec->{title} if $rec->{title};

    if (my $credits = $rec->{'artist-credit'}) {
        $meta{artist} = join(', ',
            map { $_->{name} // $_->{artist}{name} // () }
            grep { ref $_ eq 'HASH' } @$credits
        );
    }

    if (my $release = _best_release($rec->{releases} // [])) {
        $meta{album} = $release->{title};
        ($meta{year}) = ($release->{date} // '') =~ /^(\d{4})/;
    }

    if (my $tags = $rec->{tags}) {
        my ($top) = sort { $b->{count} <=> $a->{count} } @$tags;
        $meta{genre} = ucfirst($top->{name}) if $top;
    }

    return \%meta;
}

sub _best_release {
    my ($releases) = @_;
    return unless @$releases;
    my @dated = grep { $_->{date} } @$releases;
    return @dated ? $dated[0] : $releases->[0];
}

sub _get {
    my ($self, $url) = @_;

    my $gap = $MIN_GAP - (time() - $last_req_time);
    sleep($gap) if $gap > 0;
    $last_req_time = time();

    my $ua  = HTTP::Tiny->new(agent => $USER_AGENT, timeout => 10);
    my $res = $ua->get($url);
    return unless $res->{success};
    return eval { decode_json($res->{content}) };
}

sub _mb_escape {
    my ($s) = @_;
    $s =~ s/["\\]/\\$&/g;
    return $s;
}

1;

__END__

=head1 NAME

DrivePlayer::MetadataFetcher - Fetch track metadata from MusicBrainz

=head1 SYNOPSIS

  use DrivePlayer::MetadataFetcher;

  my $fetcher = DrivePlayer::MetadataFetcher->new();
  my $meta = $fetcher->fetch(
      title  => 'Come Together',
      artist => 'The Beatles',
      album  => 'Abbey Road',
  );
  # $meta = { title => ..., artist => ..., album => ..., year => ..., genre => ... }

=head1 DESCRIPTION

Queries the MusicBrainz web service to retrieve metadata for a recording.
Respects the MusicBrainz rate limit of one request per second.

Only C<title> is required.  Supplying C<artist> and/or C<album> improves
match accuracy.  Returns C<undef> if no match is found or the request fails.

=head1 METHODS

=head2 new

  my $fetcher = DrivePlayer::MetadataFetcher->new();

=head2 fetch

  my $hashref = $fetcher->fetch(title => $t, artist => $a, album => $al);

Returns a hashref with any subset of: C<title>, C<artist>, C<album>,
C<year>, C<genre>.  Returns C<undef> on failure or no match.

=cut
