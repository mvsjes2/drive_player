package DrivePlayer::GUI;

# GTK3-based music player GUI.

use DrivePlayer::Setup;
use Glib            qw( TRUE FALSE );
use Gtk3            '-init';

use Google::RestApi;
use Google::RestApi::DriveApi3;
use DrivePlayer::Config;
use DrivePlayer::DB;
use DrivePlayer::Player;
use DrivePlayer::Scanner;

Readonly my $POLL_INTERVAL_MS => 500;

has config => (
    is      => 'lazy',
    isa     => InstanceOf['DrivePlayer::Config'],
    builder => sub { DrivePlayer::Config->new() },
);

has db => (
    is      => 'lazy',
    isa     => InstanceOf['DrivePlayer::DB'],
    builder => '_build_db',
);

has rest_api => ( is => 'rw', default => sub { undef } );
has drive    => ( is => 'rw', default => sub { undef } );
has player   => ( is => 'rw', default => sub { undef } );
has scanner  => ( is => 'rw', default => sub { undef } );

has _playlist     => ( is => 'rw', isa => ArrayRef, default => sub { [] } );
has _playlist_idx => ( is => 'rw', isa => Int,      default => -1 );
has _progress_dragging => ( is => 'rw', isa => Bool, default => 0 );

# Widget accessors — set during _build_ui
has win                => ( is => 'rw' );
has sidebar_store      => ( is => 'rw' );
has sidebar_view       => ( is => 'rw' );
has track_store        => ( is => 'rw' );
has track_view         => ( is => 'rw' );
has now_playing_label  => ( is => 'rw' );
has progress           => ( is => 'rw' );
has time_label         => ( is => 'rw' );
has dur_label          => ( is => 'rw' );
has play_btn           => ( is => 'rw' );
has prev_btn           => ( is => 'rw' );
has stop_btn           => ( is => 'rw' );
has next_btn           => ( is => 'rw' );
has vol_scale          => ( is => 'rw' );
has search_entry       => ( is => 'rw' );
has statusbar          => ( is => 'rw' );
has _status_ctx        => ( is => 'rw' );

sub _build_db {
    my ($self) = @_;
    $self->config->ensure_dirs();
    return DrivePlayer::DB->new(path => $self->config->db_path());
}

sub BUILD {
    my ($self) = @_;
    $self->_init_logging();
}

sub run {
    my ($self) = @_;
    $self->_build_ui();
    $self->_load_library();

    Glib::Timeout->add($POLL_INTERVAL_MS, sub {
        $self->_player_poll();
        return TRUE;
    });

    Gtk3->main();
    $self->player->quit() if $self->player;
}

# ---- Initialisation ----

sub _init_logging {
    my ($self) = @_;
    my $level = $self->config->log_level();
    my $file  = $self->config->log_file() // '/tmp/drive_player.log';

    my $log4perl_conf = "
        log4perl.rootLogger=$level, Screen, File
        log4perl.appender.Screen=Log::Log4perl::Appender::Screen
        log4perl.appender.Screen.layout=Log::Log4perl::Layout::PatternLayout
        log4perl.appender.Screen.layout.ConversionPattern=%d [%p] %m%n
        log4perl.appender.File=Log::Log4perl::Appender::File
        log4perl.appender.File.filename=$file
        log4perl.appender.File.layout=Log::Log4perl::Layout::PatternLayout
        log4perl.appender.File.layout.ConversionPattern=%d [%p] %m%n
    ";
    Log::Log4perl->init(\$log4perl_conf) if eval { require Log::Log4perl; 1 };
}

sub _init_api {
    my ($self) = @_;
    return $self->rest_api if $self->rest_api;

    my $auth_cfg = $self->config->auth_config();
    unless ($auth_cfg->{client_id} && $auth_cfg->{client_secret}) {
        $self->_show_error("Google API credentials not configured.\nPlease edit: " .
            $self->config->config_file());
        return;
    }
    unless (-f ($auth_cfg->{token_file} // '')) {
        $self->_show_error("OAuth token file not found: $auth_cfg->{token_file}\n\n" .
            "Run the token creator from p5-google-restapi:\n" .
            "  bin/google_restapi_oauth_token_creator");
        return;
    }

    my $api = eval { Google::RestApi->new(auth => $auth_cfg) };
    if ($@) {
        $self->_show_error("Failed to initialise Google API: $@");
        return;
    }
    $self->rest_api($api);
    $self->drive(Google::RestApi::DriveApi3->new(api => $api));

    $self->player(DrivePlayer::Player->new(
        auth            => $api->auth(),
        on_track_end    => sub { $self->_on_track_end() },
        on_position     => sub { $self->_on_position(@_) },
        on_state_change => sub { $self->_on_state_change(@_) },
    ));

    return $self->rest_api;
}

# ---- UI Construction ----

sub _build_ui {
    my ($self) = @_;

    $self->win(Gtk3::Window->new('toplevel'));
    $self->win->set_title('Drive Player');
    $self->win->set_default_size(900, 600);
    $self->win->signal_connect(destroy => sub { $self->_quit() });

    my $vbox = Gtk3::Box->new('vertical', 0);
    $self->win->add($vbox);

    # Menu bar
    $vbox->pack_start($self->_build_menubar(), FALSE, FALSE, 0);

    # Toolbar
    $vbox->pack_start($self->_build_toolbar(), FALSE, FALSE, 0);

    # Main paned: sidebar | tracklist
    my $paned = Gtk3::Paned->new('horizontal');
    $paned->set_position(220);
    $vbox->pack_start($paned, TRUE, TRUE, 0);

    $paned->pack1($self->_build_sidebar(),    FALSE, FALSE);
    $paned->pack2($self->_build_tracklist(),  TRUE,  TRUE);

    # Search bar
    $vbox->pack_start($self->_build_searchbar(), FALSE, FALSE, 0);

    # Player controls
    $vbox->pack_start($self->_build_controls(), FALSE, FALSE, 0);

    # Status bar
    $self->statusbar(Gtk3::Statusbar->new());
    $self->_status_ctx($self->statusbar->get_context_id('main'));
    $vbox->pack_start($self->statusbar, FALSE, FALSE, 0);

    $self->win->show_all();
}

sub _build_menubar {
    my ($self) = @_;
    my $mb = Gtk3::MenuBar->new();

    # File menu
    my $file_menu = Gtk3::Menu->new();
    $self->_add_menu_item($file_menu, 'Add Music Folder…',  sub { $self->_add_folder_dialog() });
    $self->_add_menu_item($file_menu, 'Manage Folders…',    sub { $self->_manage_folders_dialog() });
    $file_menu->append(Gtk3::SeparatorMenuItem->new());
    $self->_add_menu_item($file_menu, 'Settings…',          sub { $self->_settings_dialog() });
    $file_menu->append(Gtk3::SeparatorMenuItem->new());
    $self->_add_menu_item($file_menu, 'Quit',               sub { $self->_quit() });
    my $file_item = Gtk3::MenuItem->new_with_label('File');
    $file_item->set_submenu($file_menu);
    $mb->append($file_item);

    # Library menu
    my $lib_menu = Gtk3::Menu->new();
    $self->_add_menu_item($lib_menu, 'Scan All Folders',    sub { $self->_scan_all() });
    $self->_add_menu_item($lib_menu, 'Clear Library',       sub { $self->_clear_library() });
    my $lib_item = Gtk3::MenuItem->new_with_label('Library');
    $lib_item->set_submenu($lib_menu);
    $mb->append($lib_item);

    # Playback menu
    my $pb_menu = Gtk3::Menu->new();
    $self->_add_menu_item($pb_menu, 'Play / Pause',  sub { $self->_toggle_play() });
    $self->_add_menu_item($pb_menu, 'Stop',          sub { $self->_stop() });
    $self->_add_menu_item($pb_menu, 'Next Track',    sub { $self->_next_track() });
    $self->_add_menu_item($pb_menu, 'Previous Track',sub { $self->_prev_track() });
    my $pb_item = Gtk3::MenuItem->new_with_label('Playback');
    $pb_item->set_submenu($pb_menu);
    $mb->append($pb_item);

    return $mb;
}

sub _add_menu_item {
    my ($self, $menu, $label, $cb) = @_;
    my $item = Gtk3::MenuItem->new_with_label($label);
    $item->signal_connect(activate => $cb);
    $menu->append($item);
}

sub _build_toolbar {
    my ($self) = @_;
    my $tb = Gtk3::Toolbar->new();
    $tb->set_style('both-horiz');

    my $scan_btn = Gtk3::ToolButton->new(
        Gtk3::Image->new_from_icon_name('view-refresh', 'small-toolbar'),
        'Scan'
    );
    $scan_btn->signal_connect(clicked => sub { $self->_scan_all() });
    $tb->insert($scan_btn, -1);

    my $add_btn = Gtk3::ToolButton->new(
        Gtk3::Image->new_from_icon_name('folder-new', 'small-toolbar'),
        'Add Folder'
    );
    $add_btn->signal_connect(clicked => sub { $self->_add_folder_dialog() });
    $tb->insert($add_btn, -1);

    $tb->insert(Gtk3::SeparatorToolItem->new(), -1);

    my $settings_btn = Gtk3::ToolButton->new(
        Gtk3::Image->new_from_icon_name('preferences-system', 'small-toolbar'),
        'Settings'
    );
    $settings_btn->signal_connect(clicked => sub { $self->_settings_dialog() });
    $tb->insert($settings_btn, -1);

    return $tb;
}

sub _build_sidebar {
    my ($self) = @_;
    my $sw = Gtk3::ScrolledWindow->new();
    $sw->set_policy('never', 'automatic');
    $sw->set_size_request(220, -1);

    # TreeStore: label (str), type (str: 'category'|'artist'|'album'|'folder'),
    #            value (str: artist name, album name, folder_id)
    my $store = Gtk3::TreeStore->new('Glib::String', 'Glib::String', 'Glib::String');
    $self->sidebar_store($store);

    my $view = Gtk3::TreeView->new($store);
    $view->set_headers_visible(FALSE);
    $view->get_selection()->set_mode('single');
    $view->signal_connect('row-activated' => sub { $self->_sidebar_activated(@_) });
    $self->sidebar_view($view);

    my $renderer = Gtk3::CellRendererText->new();
    my $col = Gtk3::TreeViewColumn->new_with_attributes('', $renderer, text => 0);
    $view->append_column($col);

    $sw->add($view);
    return $sw;
}

sub _build_tracklist {
    my ($self) = @_;
    my $sw = Gtk3::ScrolledWindow->new();
    $sw->set_policy('automatic', 'automatic');

    # ListStore columns: id, track#, title, artist, album, duration_str, drive_id
    my $store = Gtk3::ListStore->new(
        'Glib::Int',    # 0 db id
        'Glib::String', # 1 track#
        'Glib::String', # 2 title
        'Glib::String', # 3 artist
        'Glib::String', # 4 album
        'Glib::String', # 5 duration
        'Glib::String', # 6 drive_id
    );
    $self->track_store($store);

    my $view = Gtk3::TreeView->new($store);
    $view->set_headers_visible(TRUE);
    $view->set_rubber_banding(TRUE);
    $view->get_selection()->set_mode('multiple');
    $view->signal_connect('row-activated' => sub { $self->_track_activated(@_) });
    $self->track_view($view);

    my @cols = (
        ['#',        1, 40,  FALSE],
        ['Title',    2, 250, TRUE],
        ['Artist',   3, 180, TRUE],
        ['Album',    4, 180, TRUE],
        ['Duration', 5, 70,  FALSE],
    );
    for my $col_def (@cols) {
        my ($title, $idx, $width, $expand) = @$col_def;
        my $r = Gtk3::CellRendererText->new();
        my $c = Gtk3::TreeViewColumn->new_with_attributes($title, $r, text => $idx);
        $c->set_resizable(TRUE);
        $c->set_sort_column_id($idx);
        $c->set_min_width($width);
        $c->set_expand($expand);
        $view->append_column($c);
    }

    # Context menu on right-click
    $view->signal_connect('button-press-event' => sub {
        my ($w, $event) = @_;
        if ($event->button == 3) {
            $self->_tracklist_context_menu($event);
            return TRUE;
        }
        return FALSE;
    });

    $sw->add($view);
    return $sw;
}

sub _build_searchbar {
    my ($self) = @_;
    my $hbox = Gtk3::Box->new('horizontal', 4);
    $hbox->set_border_width(2);

    my $label = Gtk3::Label->new('Search:');
    $hbox->pack_start($label, FALSE, FALSE, 4);

    my $entry = Gtk3::SearchEntry->new();
    $entry->set_placeholder_text('Artist, album or title…');
    $entry->signal_connect('search-changed' => sub { $self->_on_search($entry->get_text()) });
    $self->search_entry($entry);
    $hbox->pack_start($entry, TRUE, TRUE, 0);

    my $clear = Gtk3::Button->new_with_label('Clear');
    $clear->signal_connect(clicked => sub {
        $entry->set_text('');
        $self->_load_library();
    });
    $hbox->pack_start($clear, FALSE, FALSE, 0);

    return $hbox;
}

sub _build_controls {
    my ($self) = @_;
    my $frame = Gtk3::Frame->new();
    my $vbox  = Gtk3::Box->new('vertical', 2);
    $vbox->set_border_width(4);
    $frame->add($vbox);

    # Now-playing label
    $self->now_playing_label(Gtk3::Label->new('Not playing'));
    $self->now_playing_label->set_ellipsize('end');
    $self->now_playing_label->set_xalign(0.0);
    $vbox->pack_start($self->now_playing_label, FALSE, FALSE, 0);

    # Progress bar + time labels
    my $prog_hbox = Gtk3::Box->new('horizontal', 4);
    $self->time_label(Gtk3::Label->new('0:00'));
    $self->time_label->set_size_request(40, -1);
    $prog_hbox->pack_start($self->time_label, FALSE, FALSE, 0);

    $self->progress(Gtk3::Scale->new_with_range('horizontal', 0, 100, 1));
    $self->progress->set_draw_value(FALSE);
    $self->progress->set_range(0, 1);
    $self->progress->signal_connect('button-press-event' => sub {
        $self->_progress_dragging(1); return FALSE;
    });
    $self->progress->signal_connect('button-release-event' => sub {
        $self->_progress_dragging(0);
        $self->player->seek($self->progress->get_value()) if $self->player;
        return FALSE;
    });
    $prog_hbox->pack_start($self->progress, TRUE, TRUE, 0);

    $self->dur_label(Gtk3::Label->new('0:00'));
    $self->dur_label->set_size_request(40, -1);
    $prog_hbox->pack_start($self->dur_label, FALSE, FALSE, 0);
    $vbox->pack_start($prog_hbox, FALSE, FALSE, 0);

    # Buttons + volume
    my $btn_hbox = Gtk3::Box->new('horizontal', 4);
    $vbox->pack_start($btn_hbox, FALSE, FALSE, 0);

    $self->prev_btn($self->_icon_button('media-skip-backward', sub { $self->_prev_track() }));
    $self->play_btn($self->_icon_button('media-playback-start', sub { $self->_toggle_play() }));
    $self->stop_btn($self->_icon_button('media-playback-stop',  sub { $self->_stop() }));
    $self->next_btn($self->_icon_button('media-skip-forward',   sub { $self->_next_track() }));

    $btn_hbox->pack_start($self->prev_btn, FALSE, FALSE, 0);
    $btn_hbox->pack_start($self->play_btn, FALSE, FALSE, 0);
    $btn_hbox->pack_start($self->stop_btn, FALSE, FALSE, 0);
    $btn_hbox->pack_start($self->next_btn, FALSE, FALSE, 0);

    $btn_hbox->pack_start(Gtk3::Label->new(' Vol:'), FALSE, FALSE, 8);
    $self->vol_scale(Gtk3::Scale->new_with_range('horizontal', 0, 100, 1));
    $self->vol_scale->set_value(80);
    $self->vol_scale->set_size_request(100, -1);
    $self->vol_scale->set_draw_value(FALSE);
    $self->vol_scale->signal_connect('value-changed' => sub {
        $self->player->set_volume($self->vol_scale->get_value()) if $self->player;
    });
    $btn_hbox->pack_start($self->vol_scale, FALSE, FALSE, 0);

    return $frame;
}

sub _icon_button {
    my ($self, $icon_name, $cb) = @_;
    my $btn = Gtk3::Button->new();
    $btn->set_image(Gtk3::Image->new_from_icon_name($icon_name, 'button'));
    $btn->signal_connect(clicked => $cb);
    return $btn;
}

# ---- Library loading ----

sub _load_library {
    my ($self) = @_;
    $self->_populate_sidebar();
    $self->_populate_tracklist($self->db->all_tracks());
    my $count = $self->db->track_count();
    $self->_set_status("$count tracks in library");
}

sub _populate_sidebar {
    my ($self) = @_;
    my $store = $self->sidebar_store;
    $store->clear();

    # All Tracks
    my $all_iter = $store->append(undef);
    $store->set($all_iter, 0, 'All Tracks', 1, 'all', 2, '');

    # Artists
    my $art_iter = $store->append(undef);
    $store->set($art_iter, 0, 'Artists', 1, 'category', 2, '');
    for my $artist ($self->db->all_artists()) {
        my $iter = $store->append($art_iter);
        $store->set($iter, 0, $artist, 1, 'artist', 2, $artist);
    }

    # Albums
    my $alb_iter = $store->append(undef);
    $store->set($alb_iter, 0, 'Albums', 1, 'category', 2, '');
    for my $album ($self->db->all_albums()) {
        my $iter = $store->append($alb_iter);
        $store->set($iter, 0, $album, 1, 'album', 2, $album);
    }

    # Folders
    my $fld_iter = $store->append(undef);
    $store->set($fld_iter, 0, 'Folders', 1, 'category', 2, '');
    for my $sf ($self->db->all_scan_folders()) {
        my $iter = $store->append($fld_iter);
        $store->set($iter, 0, $sf->{name}, 1, 'folder', 2, $sf->{drive_id});
    }

    $self->sidebar_view->expand_all();
}

sub _populate_tracklist {
    my ($self, @tracks) = @_;
    my $store = $self->track_store;
    $store->clear();
    $self->_playlist(\@tracks);
    $self->_playlist_idx(-1);

    for my $t (@tracks) {
        my $iter = $store->append();
        $store->set($iter,
            0, $t->{id}           // 0,
            1, _track_num_str($t->{track_number}),
            2, $t->{title}        // '(Unknown)',
            3, $t->{artist}       // '',
            4, $t->{album}        // '',
            5, _dur_str($t->{duration_ms}),
            6, $t->{drive_id}     // '',
        );
    }
}

# ---- Playback ----

sub _track_activated {
    my ($self, $view, $path, $col) = @_;
    my $idx = $path->get_indices()->[0];
    $self->_play_index($idx);
}

sub _play_index {
    my ($self, $idx) = @_;
    my $tracks = $self->_playlist;
    return unless $idx >= 0 && $idx < scalar @$tracks;

    $self->_playlist_idx($idx);
    my $track = $tracks->[$idx];

    return unless $self->_init_api();

    eval { $self->player->play($track) };
    if ($@) {
        $self->_show_error("Playback error: $@");
        return;
    }

    $self->_update_now_playing($track);
    $self->_highlight_row($idx);
}

sub _toggle_play {
    my ($self) = @_;
    if (!$self->player || $self->player->state eq 'stop') {
        my $sel  = $self->track_view->get_selection();
        my @rows = $sel->get_selected_rows();
        if (@rows) {
            $self->_play_index($rows[0]->get_indices()->[0]);
        } else {
            $self->_play_index(0);
        }
    } else {
        return unless $self->_init_api();
        $self->player->pause_resume();
    }
}

sub _stop {
    my ($self) = @_;
    return unless $self->player;
    $self->player->stop();
    $self->progress->set_value(0);
    $self->time_label->set_text('0:00');
    $self->now_playing_label->set_text('Not playing');
}

sub _next_track {
    my ($self) = @_;
    my $idx = $self->_playlist_idx + 1;
    $self->_play_index($idx) if $idx < scalar @{ $self->_playlist };
}

sub _prev_track {
    my ($self) = @_;
    my $idx = $self->_playlist_idx - 1;
    $self->_play_index($idx) if $idx >= 0;
}

# ---- Player callbacks ----

sub _on_track_end {
    my ($self) = @_;
    $self->_next_track();
}

sub _on_position {
    my ($self, $pos, $dur) = @_;
    return if $self->_progress_dragging;
    $self->progress->set_range(0, $dur) if $dur;
    $self->progress->set_value($pos)    if defined $pos;
    $self->time_label->set_text(_sec_str($pos));
    $self->dur_label->set_text(_sec_str($dur));
}

sub _on_state_change {
    my ($self, $state) = @_;
    my $icon = $state eq 'play' ? 'media-playback-pause' : 'media-playback-start';
    $self->play_btn->set_image(Gtk3::Image->new_from_icon_name($icon, 'button'));
}

sub _player_poll {
    my ($self) = @_;
    eval { $self->player->poll() } if $self->player;
}

# ---- Sidebar activation ----

sub _sidebar_activated {
    my ($self, $view, $path, $col) = @_;
    my $store = $self->sidebar_store;
    my $iter  = $store->get_iter($path);
    my $type  = $store->get($iter, 1);
    my $value = $store->get($iter, 2);

    if ($type eq 'all') {
        $self->_populate_tracklist($self->db->all_tracks());
    } elsif ($type eq 'artist') {
        $self->_populate_tracklist($self->db->tracks_by_artist($value));
    } elsif ($type eq 'album') {
        $self->_populate_tracklist($self->db->tracks_by_album($value));
    } elsif ($type eq 'folder') {
        my $sf = $self->db->get_scan_folder_by_drive_id($value) or return;
        my @tracks = $self->db->all_tracks();
        @tracks = grep { defined $_->{folder_path} &&
                         index($_->{folder_path}, $sf->{name}) == 0 } @tracks;
        $self->_populate_tracklist(@tracks);
    }

    $self->_set_status(scalar(@{ $self->_playlist }) . ' tracks');
}

# ---- Search ----

sub _on_search {
    my ($self, $query) = @_;
    if (length $query >= 2) {
        $self->_populate_tracklist($self->db->search_tracks($query));
    } elsif (length $query == 0) {
        $self->_populate_tracklist($self->db->all_tracks());
    }
}

# ---- Scanning ----

sub _scan_all {
    my ($self) = @_;
    return unless $self->_init_api();

    my @folders = @{ $self->config->music_folders() };
    unless (@folders) {
        $self->_show_error("No music folders configured.\nUse File → Add Music Folder.");
        return;
    }

    $self->_show_scan_dialog(\@folders);
}

sub _show_scan_dialog {
    my ($self, $folders) = @_;

    my $dlg = Gtk3::Dialog->new_with_buttons(
        'Scanning Library', $self->win,
        [qw/ modal destroy-with-parent /],
        'Stop', 'cancel',
    );
    $dlg->set_default_size(400, 160);

    my $content = $dlg->get_content_area();
    my $vbox = Gtk3::Box->new('vertical', 8);
    $vbox->set_border_width(12);
    $content->pack_start($vbox, TRUE, TRUE, 0);

    my $status_lbl = Gtk3::Label->new('Preparing…');
    $status_lbl->set_xalign(0.0);
    $status_lbl->set_ellipsize('middle');
    $vbox->pack_start($status_lbl, FALSE, FALSE, 0);

    my $progress = Gtk3::ProgressBar->new();
    $progress->set_pulse_step(0.05);
    $vbox->pack_start($progress, FALSE, FALSE, 0);

    my $count_lbl = Gtk3::Label->new('0 tracks found');
    $count_lbl->set_xalign(0.0);
    $vbox->pack_start($count_lbl, FALSE, FALSE, 0);

    $dlg->show_all();

    my $track_count = 0;
    my $total       = scalar @$folders;
    my $current     = 0;
    my $stopped     = FALSE;

    my $scanner = DrivePlayer::Scanner->new(
        drive    => $self->drive,
        db       => $self->db,
        on_progress => sub {
            my ($msg) = @_;
            $status_lbl->set_text($msg);
            $progress->pulse();
            Gtk3->main_iteration_do(FALSE) while Gtk3->events_pending();
        },
        on_track_found => sub {
            $track_count++;
            $count_lbl->set_text("$track_count tracks found");
            Gtk3->main_iteration_do(FALSE) while Gtk3->events_pending();
        },
    );
    $self->scanner($scanner);

    $dlg->signal_connect(response => sub {
        $stopped = TRUE;
        $scanner->stop();
    });

    # Scan each folder in sequence, processing GTK events between each
    for my $folder (@$folders) {
        last if $stopped;
        $current++;
        $status_lbl->set_text("Scanning folder $current/$total: $folder->{name}");
        $progress->set_fraction($current / ($total + 1));
        Gtk3->main_iteration_do(FALSE) while Gtk3->events_pending();

        eval {
            $scanner->scan_folder($folder->{id}, $folder->{name});
        };
        $self->_set_status("Error scanning $folder->{name}: $@") if $@;
    }

    $progress->set_fraction(1.0);
    $status_lbl->set_text("Done. $track_count tracks found.");
    Gtk3->main_iteration_do(FALSE) while Gtk3->events_pending();
    sleep 1;

    $dlg->destroy();
    $self->_load_library();
}

# ---- Dialogs ----

sub _add_folder_dialog {
    my ($self) = @_;
    return unless $self->_init_api();

    my $dlg = Gtk3::Dialog->new_with_buttons(
        'Add Music Folder', $self->win,
        [qw/ modal destroy-with-parent /],
        'OK',     'ok',
        'Cancel', 'cancel',
    );
    $dlg->set_default_size(400, 140);

    my $grid = Gtk3::Grid->new();
    $grid->set_row_spacing(6);
    $grid->set_column_spacing(8);
    $grid->set_border_width(12);
    $dlg->get_content_area()->add($grid);

    $grid->attach(Gtk3::Label->new('Drive Folder ID:'), 0, 0, 1, 1);
    my $id_entry = Gtk3::Entry->new();
    $id_entry->set_placeholder_text('e.g. 1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgVE2');
    $id_entry->set_hexpand(TRUE);
    $grid->attach($id_entry, 1, 0, 1, 1);

    $grid->attach(Gtk3::Label->new('Display Name:'), 0, 1, 1, 1);
    my $name_entry = Gtk3::Entry->new();
    $name_entry->set_placeholder_text('e.g. My Music');
    $name_entry->set_hexpand(TRUE);
    $grid->attach($name_entry, 1, 1, 1, 1);

    my $hint = Gtk3::Label->new(
        '<small>Find the folder ID in the Google Drive URL:\n' .
        'drive.google.com/drive/folders/<b>FOLDER_ID</b></small>'
    );
    $hint->set_use_markup(TRUE);
    $hint->set_xalign(0.0);
    $grid->attach($hint, 0, 2, 2, 1);

    $dlg->show_all();
    my $response = $dlg->run();

    if ($response eq 'ok') {
        my $id   = $id_entry->get_text();
        my $name = $name_entry->get_text() || 'Music Folder';
        if ($id) {
            $self->config->add_music_folder($id, $name);
            $self->config->save();
            $self->_set_status("Added folder: $name. Use Library → Scan All to index it.");
        }
    }
    $dlg->destroy();
}

sub _manage_folders_dialog {
    my ($self) = @_;
    my $dlg = Gtk3::Dialog->new_with_buttons(
        'Manage Folders', $self->win,
        [qw/ modal destroy-with-parent /],
        'Close', 'close',
    );
    $dlg->set_default_size(500, 300);

    my $store = Gtk3::ListStore->new('Glib::String', 'Glib::String');
    for my $f (@{ $self->config->music_folders() }) {
        my $iter = $store->append();
        $store->set($iter, 0, $f->{name}, 1, $f->{id});
    }

    my $view = Gtk3::TreeView->new($store);
    my $r = Gtk3::CellRendererText->new();
    $view->append_column(Gtk3::TreeViewColumn->new_with_attributes('Name',      $r, text => 0));
    $view->append_column(Gtk3::TreeViewColumn->new_with_attributes('Drive ID',  $r, text => 1));

    my $sw = Gtk3::ScrolledWindow->new();
    $sw->add($view);

    my $remove_btn = Gtk3::Button->new_with_label('Remove Selected');
    $remove_btn->signal_connect(clicked => sub {
        my $sel  = $view->get_selection();
        my ($model, $iter) = $sel->get_selected();
        return unless $iter;
        my $id = $model->get($iter, 1);
        $self->config->remove_music_folder($id);
        $self->config->save();
        $self->db->delete_scan_folder($id);
        $store->remove($iter);
        $self->_load_library();
    });

    my $vbox = $dlg->get_content_area();
    $vbox->pack_start($sw,         TRUE,  TRUE,  0);
    $vbox->pack_start($remove_btn, FALSE, FALSE, 4);
    $dlg->show_all();
    $dlg->run();
    $dlg->destroy();
}

sub _settings_dialog {
    my ($self) = @_;
    my $dlg = Gtk3::Dialog->new_with_buttons(
        'Settings', $self->win,
        [qw/ modal destroy-with-parent /],
        'Save',   'ok',
        'Cancel', 'cancel',
    );
    $dlg->set_default_size(500, 260);

    my $grid = Gtk3::Grid->new();
    $grid->set_row_spacing(8);
    $grid->set_column_spacing(8);
    $grid->set_border_width(12);
    $dlg->get_content_area()->add($grid);

    my $row = 0;
    my %entries;
    for my $field (
        ['client_id',     'OAuth Client ID:'],
        ['client_secret', 'OAuth Client Secret:'],
        ['token_file',    'Token File:'],
    ) {
        my ($key, $lbl) = @$field;
        $grid->attach(Gtk3::Label->new($lbl), 0, $row, 1, 1);
        my $e = Gtk3::Entry->new();
        $e->set_hexpand(TRUE);
        $e->set_text($self->config->auth_config()->{$key} // '');
        $e->set_visibility(FALSE) if $key eq 'client_secret';
        $grid->attach($e, 1, $row, 1, 1);
        $entries{$key} = $e;
        $row++;
    }

    $grid->attach(Gtk3::Label->new('Config file:'), 0, $row, 1, 1);
    my $cfg_lbl = Gtk3::Label->new($self->config->config_file());
    $cfg_lbl->set_xalign(0.0);
    $cfg_lbl->set_selectable(TRUE);
    $grid->attach($cfg_lbl, 1, $row, 1, 1);

    $dlg->show_all();
    my $response = $dlg->run();

    if ($response eq 'ok') {
        my $auth = $self->config->auth_config();
        for my $key (keys %entries) {
            $auth->{$key} = $entries{$key}->get_text();
        }
        $self->config->save();
        $self->_set_status('Settings saved. Restart to apply API credential changes.');
    }
    $dlg->destroy();
}

sub _tracklist_context_menu {
    my ($self, $event) = @_;
    my $menu = Gtk3::Menu->new();

    my $play_item = Gtk3::MenuItem->new_with_label('Play');
    $play_item->signal_connect(activate => sub {
        my $sel  = $self->track_view->get_selection();
        my @rows = $sel->get_selected_rows();
        if (@rows) {
            $self->_play_index($rows[0]->get_indices()->[0]);
        }
    });
    $menu->append($play_item);

    $menu->show_all();
    $menu->popup_at_pointer($event);
}

sub _clear_library {
    my ($self) = @_;
    my $dlg = Gtk3::MessageDialog->new(
        $self->win, 'destroy-with-parent', 'question', 'yes-no',
        'Clear the entire music library? This will remove all scanned tracks.'
    );
    my $response = $dlg->run();
    $dlg->destroy();
    return unless $response eq 'yes';

    for my $sf ($self->db->all_scan_folders()) {
        $self->db->delete_scan_folder($sf->{drive_id});
    }
    $self->_load_library();
    $self->_set_status('Library cleared.');
}

# ---- Helpers ----

sub _update_now_playing {
    my ($self, $track) = @_;
    my $text = '';
    $text .= $track->{artist} . ' — ' if $track->{artist};
    $text .= $track->{title} // '(Unknown)';
    $text .= '  [' . $track->{album} . ']' if $track->{album};
    $self->now_playing_label->set_text($text);
    $self->win->set_title("Drive Player — $text");
}

sub _highlight_row {
    my ($self, $idx) = @_;
    my $path = Gtk3::TreePath->new_from_indices($idx);
    $self->track_view->get_selection()->select_path($path);
    $self->track_view->scroll_to_cell($path, undef, TRUE, 0.5, 0.0);
}

sub _set_status {
    my ($self, $msg) = @_;
    $self->statusbar->pop($self->_status_ctx);
    $self->statusbar->push($self->_status_ctx, $msg);
}

sub _show_error {
    my ($self, $msg) = @_;
    my $dlg = Gtk3::MessageDialog->new(
        $self->win, 'destroy-with-parent', 'error', 'ok', $msg
    );
    $dlg->run();
    $dlg->destroy();
}

sub _quit {
    my ($self) = @_;
    $self->player->quit() if $self->player;
    Gtk3->main_quit();
}

# ---- Formatting helpers ----

sub _dur_str {
    my ($ms) = @_;
    return '' unless defined $ms && $ms > 0;
    return _sec_str($ms / 1000);
}

sub _sec_str {
    my ($sec) = @_;
    return '0:00' unless defined $sec;
    $sec = int($sec);
    my $m = int($sec / 60);
    my $s = $sec % 60;
    return sprintf("%d:%02d", $m, $s);
}

sub _track_num_str {
    my ($n) = @_;
    return '' unless defined $n && $n > 0;
    return sprintf("%02d", $n);
}

1;

__END__

=head1 NAME

DrivePlayer::GUI - GTK3 application window for DrivePlayer

=head1 SYNOPSIS

  use DrivePlayer::GUI;

  DrivePlayer::GUI->new->run;

=head1 DESCRIPTION

The top-level L<Moo> class that constructs and drives the GTK3 user
interface.  Responsibilities include:

=over 4

=item *

Building the main window with a sidebar (artists / albums / folders), a
track list, and playback controls (play/pause, stop, seek, volume).

=item *

Lazily initialising the Google REST API connection and
L<DrivePlayer::Player> on first use, so start-up is fast even when network
access is unavailable.

=item *

Running folder scans (via L<DrivePlayer::Scanner>) in a background thread
with live progress reporting.

=item *

Persisting configuration changes (music folder list, OAuth2 credentials)
through L<DrivePlayer::Config>.

=back

Requires the GTK3 system libraries and the L<Gtk3> and L<Glib> Perl
modules.  Not covered by the unit test suite.

=head1 METHODS

=head2 new

  my $gui = DrivePlayer::GUI->new;

Constructs the application object.  The window is not shown until L</run>
is called.

=head2 run

  $gui->run;

Build and display the main window, then enter the GTK3 main loop.  Does not
return until the window is closed.

=cut
