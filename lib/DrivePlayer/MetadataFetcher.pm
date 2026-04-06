package DrivePlayer::MetadataFetcher;

use strict;
use warnings;
use HTTP::Tiny;
use JSON::PP     qw( decode_json );
use URI::Escape  qw( uri_escape );
use Time::HiRes  qw( sleep time );

my $USER_AGENT   = 'DrivePlayer/1.0 (https://github.com/mvsjes2/drive_player)';
my $ITUNES_BASE  = 'https://itunes.apple.com/search';
my $MB_BASE      = 'https://musicbrainz.org/ws/2';
my $MB_MIN_GAP   = 1.1;   # MusicBrainz rate limit: 1 req/sec

my $last_mb_req  = 0;

sub new { return bless {}, shift }

# Try iTunes first (better fuzzy matching, no rate limit); fall back to MusicBrainz.
sub fetch {
    my ($self, %args) = @_;
    my $title  = $args{title}  or return;
    my $artist = $args{artist} // '';
    my $album  = $args{album}  // '';

    return $self->_fetch_itunes($title, $artist, $album)
        // $self->_fetch_musicbrainz($title, $artist, $album);
}

# ---------- iTunes ----------

sub _fetch_itunes {
    my ($self, $title, $artist, $album) = @_;

    # Build a simple keyword query: artist + title works best
    my $term = join(' ', grep { length } $artist, $title);
    my $url  = $ITUNES_BASE . '?term=' . uri_escape($term)
             . '&entity=song&media=music&limit=5';

    my $data = $self->_get_plain($url) or return;
    my $results = $data->{results} or return;
    return unless @$results;

    # Pick the result whose title and artist best match what we have
    my $best = _best_itunes_match($results, $title, $artist, $album);
    return unless $best;

    my %meta;
    $meta{title}        = $best->{trackName}        if $best->{trackName};
    $meta{artist}       = $best->{artistName}        if $best->{artistName};
    $meta{album}        = $best->{collectionName}    if $best->{collectionName};
    $meta{genre}        = $best->{primaryGenreName}  if $best->{primaryGenreName};
    $meta{track_number} = $best->{trackNumber}       if $best->{trackNumber};
    ($meta{year})       = ($best->{releaseDate} // '') =~ /^(\d{4})/;

    return \%meta;
}

sub _best_itunes_match {
    my ($results, $want_title, $want_artist, $want_album) = @_;

    my $score = sub {
        my ($r) = @_;
        my $s = 0;
        $s += 3 if $want_title  && _fuzzy_match($r->{trackName},     $want_title);
        $s += 2 if $want_artist && _fuzzy_match($r->{artistName},     $want_artist);
        $s += 1 if $want_album  && _fuzzy_match($r->{collectionName}, $want_album);
        return $s;
    };

    my ($best) = sort { $score->($b) <=> $score->($a) } @$results;

    # Require at least a title match
    return unless $want_title && _fuzzy_match($best->{trackName}, $want_title);
    return $best;
}

# Case-insensitive substring / word match
sub _fuzzy_match {
    my ($haystack, $needle) = @_;
    return unless defined $haystack && defined $needle && length $needle;
    return index(lc($haystack), lc($needle)) >= 0
        || index(lc($needle), lc($haystack)) >= 0;
}

# ---------- MusicBrainz ----------

sub _fetch_musicbrainz {
    my ($self, $title, $artist, $album) = @_;

    # Use fuzzy (~) matching and progressively relax constraints
    my @attempts = (
        # Most specific: title + artist + album (fuzzy)
        ( $artist && $album
            ? 'recording:' . _mb_escape($title) . '~ AND artist:'
              . _mb_escape($artist) . '~ AND release:' . _mb_escape($album) . '~'
            : () ),
        # title + artist
        ( $artist
            ? 'recording:' . _mb_escape($title) . '~ AND artist:' . _mb_escape($artist) . '~'
            : () ),
        # title only
        'recording:' . _mb_escape($title) . '~',
    );

    for my $query (@attempts) {
        my $url = "$MB_BASE/recording?query=" . uri_escape($query)
                . '&fmt=json&limit=5&inc=releases+artist-credits+tags';
        my $data = $self->_get_mb($url) or next;
        my $recs = $data->{recordings} or next;
        next unless @$recs;
        my $meta = _parse_mb($recs->[0]);
        return $meta if $meta && %$meta;
    }
    return;
}

sub _parse_mb {
    my ($rec) = @_;
    my %meta;

    $meta{title} = $rec->{title} if $rec->{title};

    if (my $credits = $rec->{'artist-credit'}) {
        $meta{artist} = join(', ',
            map { $_->{name} // $_->{artist}{name} // () }
            grep { ref $_ eq 'HASH' } @$credits
        );
    }

    if (my $release = _best_mb_release($rec->{releases} // [])) {
        $meta{album} = $release->{title};
        ($meta{year}) = ($release->{date} // '') =~ /^(\d{4})/;
    }

    if (my $tags = $rec->{tags}) {
        my ($top) = sort { $b->{count} <=> $a->{count} } @$tags;
        $meta{genre} = ucfirst($top->{name}) if $top;
    }

    return \%meta;
}

sub _best_mb_release {
    my ($releases) = @_;
    return unless @$releases;
    my @dated = grep { $_->{date} } @$releases;
    return @dated ? $dated[0] : $releases->[0];
}

# ---------- HTTP ----------

sub _get_plain {
    my ($self, $url) = @_;
    my $ua  = HTTP::Tiny->new(agent => $USER_AGENT, timeout => 10);
    my $res = $ua->get($url);
    return unless $res->{success};
    return eval { decode_json($res->{content}) };
}

sub _get_mb {
    my ($self, $url) = @_;
    my $gap = $MB_MIN_GAP - (time() - $last_mb_req);
    sleep($gap) if $gap > 0;
    $last_mb_req = time();
    return $self->_get_plain($url);
}

sub _mb_escape {
    my ($s) = @_;
    $s =~ s/["\\+\-&|!(){}\[\]^~*?:\/]/\\$&/g;
    return $s;
}

1;

__END__

=head1 NAME

DrivePlayer::MetadataFetcher - Fetch track metadata from iTunes and MusicBrainz

=head1 SYNOPSIS

  use DrivePlayer::MetadataFetcher;

  my $fetcher = DrivePlayer::MetadataFetcher->new();
  my $meta = $fetcher->fetch(
      title  => 'Come Together',
      artist => 'The Beatles',   # optional but improves accuracy
      album  => 'Abbey Road',    # optional
  );
  # $meta = { title=>, artist=>, album=>, year=>, genre=>, track_number=> }

=head1 DESCRIPTION

Queries the iTunes Search API first (good fuzzy matching, no rate limit,
returns genre directly) then falls back to MusicBrainz (better for
classical and non-commercial music).

MusicBrainz requests are rate-limited to one per second as required.
iTunes requests are unrestricted.

Only C<title> is required.  Supplying C<artist> and/or C<album> improves
match accuracy.

=head1 METHODS

=head2 new

  my $fetcher = DrivePlayer::MetadataFetcher->new();

=head2 fetch

  my $hashref = $fetcher->fetch(title => $t, artist => $a, album => $al);

Returns a hashref with any subset of: C<title>, C<artist>, C<album>,
C<year>, C<genre>, C<track_number>.  Returns C<undef> on failure or
no match found in either source.

=cut
