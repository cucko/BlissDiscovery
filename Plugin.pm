package Plugins::BlissDiscovery::Plugin;

#
# Bliss Discovery - adds a "Bliss Discovery" section to the Material Skin home screen.
# Each tile shows the artwork of a randomly chosen track, every tile from a
# different genre. Clicking a tile starts a Bliss mix seeded from that track
# (via the Bliss Mixer plugin's "blissmixer mix" command).
#

use strict;
use warnings;
use base qw(Slim::Plugin::Base);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Timers;
use Slim::Control::Request;
use Slim::Music::VirtualLibraries;

my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.blissdiscovery',
	defaultLevel => 'WARN',
	description  => 'PLUGIN_BLISSDISCOVERY',
});

my $prefs = preferences('plugin.blissdiscovery');

use constant MAX_TILES     => 12;
use constant HOME_EXTRA_ID => 'blissdiscovery';

# Material's "More" button on a section shows this many times the normal
# number of tiles.
use constant MORE_FACTOR => 3;

# Material never asks for more than this many items for a home-screen row
# (MAX_HOME_EXTRA_ROW in its JS); the "More" button asks for a lot more, which
# is how we tell the two apart.
use constant HOME_ROW_MAX => 30;

# Tile sets, keyed by library id ('' = whole library). Each value is an
# arrayref of tiles: { trackid, title, artist, genre, genreid, coverid }
my %tileSets = ();
my $registeredWithMaterial = 0;

# Bliss Mixer returns at most this many tracks per request
use constant BLISS_MAX_COUNT => 50;

sub getDisplayName { 'PLUGIN_BLISSDISCOVERY' }

sub initPlugin {
	my $class = shift;

	$prefs->init({
		numTiles         => 6,
		mixCount         => 20,
		dstm             => 0,
		refreshAfterPlay => 1,
		refreshHours     => 24,
		library          => '',     # '' = all music, 'player' = player's library view, else a virtual library id
	});

	$prefs->setValidate({ validator => 'intlimit', low => 1, high => MAX_TILES }, 'numTiles');
	$prefs->setValidate({ validator => 'intlimit', low => 1, high => 50 },        'mixCount');
	$prefs->setValidate({ validator => 'intlimit', low => 0, high => 720 },       'refreshHours');

	$prefs->setChange(sub { refreshTiles(); },   'numTiles');
	$prefs->setChange(sub { $registeredWithMaterial = 0; refreshTiles(); }, 'library');
	$prefs->setChange(sub { _scheduleTimer(); }, 'refreshHours');

	if ( main::WEBUI ) {
		require Plugins::BlissDiscovery::Settings;
		Plugins::BlissDiscovery::Settings->new;
	}

	# CLI
	#   blissdiscovery playlist play tile:<n>   - start a Bliss mix from tile n (needs player)
	#   blissdiscovery refresh                  - re-pick all tiles
	#   blissdiscovery list                     - show current tiles
	Slim::Control::Request::addDispatch(['blissdiscovery', 'playlist', 'play'], [1, 0, 1, \&_cliPlay]);
	Slim::Control::Request::addDispatch(['blissdiscovery', 'refresh'],          [0, 0, 0, \&_cliRefresh]);
	Slim::Control::Request::addDispatch(['blissdiscovery', 'list'],             [0, 1, 0, \&_cliList]);

	# Re-pick tiles after a library rescan
	Slim::Control::Request::subscribe(\&_onRescanDone, [['rescan'], ['done']]);

	$class->SUPER::initPlugin(@_);
}

sub postinitPlugin {
	_registerWithMaterial();

	# Give the database a few seconds to settle after startup, then build tiles.
	Slim::Utils::Timers::setTimer(undef, time() + 5, \&refreshTiles);
	_scheduleTimer();
}

sub shutdownPlugin {
	Slim::Utils::Timers::killTimers(undef, \&refreshTiles);
	Slim::Utils::Timers::killTimers(undef, \&_periodicRefresh);
	Slim::Control::Request::unsubscribe(\&_onRescanDone);
}

# ---------------------------------------------------------------------------
# Material Skin home-screen section
# ---------------------------------------------------------------------------

sub _registerWithMaterial {
	return if $registeredWithMaterial;

	eval { require Plugins::MaterialSkin::Plugin; };
	if ( $@ || !Plugins::MaterialSkin::Plugin->can('registerHomeExtra') ) {
		$log->warn('Material Skin (with home-extra support) not found - tiles will not be shown');
		return;
	}

	# In 'player' mode the section depends on which player is selected, so ask
	# Material to call us with the player.
	my $needsPlayer = ( $prefs->get('library') || '' ) eq 'player' ? 1 : 0;

	Plugins::MaterialSkin::Plugin->registerHomeExtra( HOME_EXTRA_ID, {
		title       => 'PLUGIN_BLISSDISCOVERY_HOME_TITLE',
		subtitle    => 'PLUGIN_BLISSDISCOVERY_HOME_SUBTITLE',
		icon        => 'MTL_icon_auto_awesome',
		needsPlayer => $needsPlayer,
		# Lower bound for the quantity Material asks us for - must stay below
		# HOME_ROW_MAX so that a "More" request is still recognisable.
		count       => MAX_TILES + 1,
		handler     => \&_homeExtraHandler,
	});

	$registeredWithMaterial = 1;
	main::INFOLOG && $log->info('Registered home-screen section with Material Skin');
}

# Called by Material Skin when it builds the home screen, and again (with a
# much larger quantity) when the user presses the section's "More" button.
# Must call $cb with a SlimBrowse-style result:
# { item_loop => [...], count => N, offset => 0 }
sub _homeExtraHandler {
	my ($client, $cb, $args) = @_;

	my $lib      = _effectiveLibrary($client);
	my $numTiles = $prefs->get('numTiles') || 6;
	my $quantity = $args && $args->{quantity} ? $args->{quantity} : 0;

	# "More" was pressed: show MORE_FACTOR times as many tiles
	my $isMore = $quantity > HOME_ROW_MAX;
	my $want   = $isMore ? $numTiles * MORE_FACTOR : $numTiles;

	my $tiles = _tilesFor( $lib, $want );
	my $shown = @$tiles < $want ? scalar @$tiles : $want;

	my @items;

	my $idx = 0;

	for my $tile ( @$tiles[ 0 .. $shown - 1 ] ) {
		my $subtitle = $tile->{artist} || '';
		$subtitle .= ( $subtitle ? " - " : '' ) . $tile->{genre} if $tile->{genre};

		push @items, {
			text      => $tile->{title} . ( $subtitle ? "\n$subtitle" : '' ),
			'icon-id' => $tile->{coverid} ? "music/$tile->{coverid}/cover.jpg" : 'html/images/cover.png',
			actions   => {
				go => {
					cmd    => [ 'blissdiscovery', 'playlist', 'play' ],
					params => { tile => $idx, ( $lib ne '' ? ( lib => $lib ) : () ) },
				},
			},
		};
		$idx++;
	}

	# nextWindow 'refresh' makes Material re-run the command that built the
	# current list once the tiles have been re-picked. On the home screen that
	# is a no-op (the refresh-home notification already updates it), but on the
	# "More" page it is the only thing that redraws the list.
	push @items, {
		text       => string('PLUGIN_BLISSDISCOVERY_REGENERATE'),
		'icon-id'  => 'MTL_icon_refresh',
		nextWindow => 'refresh',
		actions    => {
			go => {
				cmd => [ 'blissdiscovery', 'refresh' ],
			},
		},
	};

	# Material only draws the "More" button when the reported count is greater
	# than the number of items it asked for, so on the home row claim the whole
	# expanded set (and at least one more than was asked for). On the "More"
	# page the count has to match what we return, or Material keeps paging.
	my $count = scalar @items;

	if ( !$isMore ) {
		my $available = $numTiles * MORE_FACTOR + 1;   # tiles + "Regenerate"
		$count = $available > $quantity ? $available : $quantity + 1;
	}

	$cb->({
		item_loop => \@items,
		count     => $count,
		offset    => 0,
	});
}

# Ask Material Skin (all connected browsers) to re-fetch the home screen sections
sub _signalMaterialRefresh {
	Slim::Control::Request::notifyFromArray(undef, ['material-skin', 'notification', 'internal', 'refresh-home']);
}

sub _materialNotify {
	my ($type, $msg, $client) = @_;
	Slim::Control::Request::notifyFromArray(undef, ['material-skin', 'notification', $type, $msg, undef, $client ? $client->id : undef, 5]);
}

# ---------------------------------------------------------------------------
# Starting a mix
# ---------------------------------------------------------------------------

sub _cliPlay {
	my $request = shift;
	my $client  = $request->client();
	my $idx     = $request->getParam('tile');
	my $lib     = $request->getParam('lib');
	$lib = _effectiveLibrary($client) unless defined $lib;
	$lib = '' unless Slim::Music::VirtualLibraries->getRealId($lib);
	my $tiles   = _tilesFor($lib);
	my $tile    = ( defined $idx && $idx =~ /^\d+$/ ) ? $tiles->[$idx] : undef;

	if ( !$client ) {
		$log->warn('No player - cannot start mix');
		$request->setStatusBadParams();
		return;
	}

	if ( !$tile ) {
		$log->warn("No tile at index " . ( defined $idx ? $idx : 'undef' ));
		_materialNotify( 'error', string('PLUGIN_BLISSDISCOVERY_NO_TILE'), $client );
		$request->setStatusBadParams();
		return;
	}

	my $count = $prefs->get('mixCount') || 20;

	# When restricting to a library, over-fetch so that enough tracks survive the filter
	my $askFor = $lib ne '' ? $count * 3 : $count;
	$askFor = BLISS_MAX_COUNT if $askFor > BLISS_MAX_COUNT;

	my $cmd = [ 'blissmixer', 'mix', "track_id:$tile->{trackid}", "count:$askFor" ];

	main::INFOLOG && $log->info( "Requesting Bliss mix for player " . $client->name . ": " . join( ' ', @$cmd ) );

	$request->setStatusProcessing();

	my $mixReq = Slim::Control::Request::executeRequest( undef, $cmd );

	if ( !$mixReq ) {
		$log->error('Could not execute "blissmixer mix" - is the Bliss Mixer plugin installed and enabled?');
		_materialNotify( 'error', string('PLUGIN_BLISSDISCOVERY_NO_BLISS'), $client );
		$request->setStatusDone();
		return;
	}

	if ( $mixReq->isStatusProcessing ) {
		$mixReq->callbackFunction( sub { _loadMix( $client, $mixReq, $tile, $idx, $lib, $count, $request ); } );
	}
	else {
		_loadMix( $client, $mixReq, $tile, $idx, $lib, $count, $request );
	}
}

sub _loadMix {
	my ($client, $mixReq, $tile, $idx, $lib, $count, $request) = @_;

	my @ids;
	for my $item ( @{ $mixReq->getResult('titles_loop') || [] } ) {
		push @ids, $item->{id} if $item->{id};
	}

	if ( $lib ne '' && @ids ) {
		my $before = scalar @ids;
		@ids = _filterToLibrary( $lib, \@ids );
		main::INFOLOG && $log->info( "Library filter kept " . scalar(@ids) . " of $before tracks" );
	}
	splice( @ids, $count ) if @ids > $count;

	my $label = $tile->{title} . ( $tile->{artist} ? ' - ' . $tile->{artist} : '' );

	if ( !@ids ) {
		$log->warn("Bliss returned no tracks for track_id $tile->{trackid} ($label) - has it been analysed?");
		_materialNotify( 'error', sprintf( string('PLUGIN_BLISSDISCOVERY_NO_MIX'), $label ), $client );
		$request->addResult( 'count', 0 );
		$request->setStatusDone();
		return;
	}

	# Put the seed track first so the mix starts with the song on the tile
	@ids = ( $tile->{trackid}, grep { $_ != $tile->{trackid} } @ids );

	main::INFOLOG && $log->info( "Loading " . scalar(@ids) . " tracks on " . $client->name );

	$client->execute( [ 'playlistcontrol', 'cmd:load', 'track_id:' . join( ',', @ids ) ] );

	if ( $prefs->get('dstm') ) {
		$client->execute( [ 'playerpref', 'plugin.dontstopthemusic:provider', 'BLISSMIXER_DSTM' ] );
		$client->execute( [ 'playlist', 'repeat', '0' ] );
	}

	_materialNotify( 'info', sprintf( string('PLUGIN_BLISSDISCOVERY_STARTED'), $tile->{title}, $tile->{artist} ), $client );

	$request->addResult( 'count', scalar @ids );
	$request->setStatusDone();

	if ( $prefs->get('refreshAfterPlay') ) {
		Slim::Utils::Timers::setTimer( undef, time() + 2, sub { _replaceTile( $lib, $idx ); } );
	}
}

# ---------------------------------------------------------------------------
# Refresh
# ---------------------------------------------------------------------------

sub refreshTiles {
	if ( !Slim::Schema::hasLibrary() ) {
		$log->warn('No library available yet, retrying in 30s');
		Slim::Utils::Timers::setTimer(undef, time() + 30, \&refreshTiles);
		return;
	}

	if ( Slim::Music::Import->stillScanning ) {
		main::INFOLOG && $log->info('Scan in progress, retrying in 60s');
		Slim::Utils::Timers::setTimer(undef, time() + 60, \&refreshTiles);
		return;
	}

	_registerWithMaterial();

	# Drop everything; sets are rebuilt on demand (immediately for the default set)
	%tileSets = ();
	my $tiles = _tilesFor( _effectiveLibrary(undef) );

	main::INFOLOG && $log->info( sprintf( 'Picked %d tiles', scalar @$tiles ) );

	_signalMaterialRefresh();
	Slim::Control::Request::notifyFromArray(undef, ['blissdiscovery', 'changed']);
}

# ---------------------------------------------------------------------------
# Library handling
# ---------------------------------------------------------------------------

# Returns the library id to use ('' = whole library) according to the setting
sub _effectiveLibrary {
	my $client = shift;
	my $pref   = $prefs->get('library') || '';

	return '' if $pref eq '';

	if ( $pref eq 'player' ) {
		return '' unless $client;
		return Slim::Music::VirtualLibraries->getLibraryIdForClient($client) || '';
	}

	return Slim::Music::VirtualLibraries->getRealId($pref) || '';
}

# Return the tile set for a library, growing it to $want tiles if needed.
# Tiles are only ever appended, so tile indices stay valid.
sub _tilesFor {
	my ($lib, $want) = @_;
	$lib = '' unless defined $lib;

	my $n = $prefs->get('numTiles') || 6;
	$want = $n unless $want && $want > $n;
	$want = $n * MORE_FACTOR if $want > $n * MORE_FACTOR;

	my $tiles = $tileSets{$lib} ||= [];

	if ( @$tiles < $want ) {
		my %genres = map { $_->{genreid} ? ( $_->{genreid} => 1 ) : () } @$tiles;
		my %tracks = map { $_->{trackid} => 1 } @$tiles;

		push @$tiles, _pickTracks( $want - @$tiles, \%genres, $lib, \%tracks );
		main::INFOLOG && $log->info( sprintf( "Tile set for library '%s' now has %d tiles (wanted %d)", $lib, scalar @$tiles, $want ) );
	}

	return $tiles;
}

# Keep only the track ids that are part of the given library, preserving order
sub _filterToLibrary {
	my ($lib, $ids) = @_;
	return @$ids unless $lib ne '' && @$ids;

	my $dbh = Slim::Schema->dbh;
	my $placeholders = join( ',', ('?') x scalar @$ids );
	my $sth = $dbh->prepare_cached("SELECT track FROM library_track WHERE library = ? AND track IN ($placeholders)");
	$sth->execute( $lib, @$ids );

	my %keep;
	while ( my ($id) = $sth->fetchrow_array ) {
		$keep{$id} = 1;
	}
	$sth->finish;

	return grep { $keep{$_} } @$ids;
}

# ---------------------------------------------------------------------------
# Tile selection
# ---------------------------------------------------------------------------

# Pick up to $n tracks, each from a different genre. $exclude is a hashref of
# genre ids that must not be used, $skip an optional hashref of track ids to
# leave out. $lib restricts to a virtual library.
sub _pickTracks {
	my ($n, $exclude, $lib, $skip) = @_;
	$lib  = '' unless defined $lib;
	$skip = {} unless defined $skip;

	my @picked;
	my $dbh = Slim::Schema->dbh;

	# Genres (that actually have tracks in the chosen library), random order
	my $genreSql = $lib ne ''
		? "SELECT DISTINCT gt.genre FROM genre_track gt JOIN library_track lt ON lt.track = gt.track WHERE lt.library = ? ORDER BY RANDOM()"
		: "SELECT id FROM genres ORDER BY RANDOM()";
	my @genreIds = map { $_->[0] } @{ $dbh->selectall_arrayref( $genreSql, undef, ( $lib ne '' ? ($lib) : () ) ) || [] };

	for my $genreId (@genreIds) {
		last if @picked >= $n;
		next if $exclude->{$genreId};

		my $track = _randomTrack( $genreId, $lib );
		next unless $track;
		next if $skip->{ $track->id };

		my $tile = _tileFromTrack( $track, $genreId );
		next unless $tile;

		push @picked, $tile;
		$exclude->{$genreId} = 1;
	}

	# Not enough genres with usable tracks: fill up with random tracks.
	my $guard = 0;
	while ( @picked < $n && $guard++ < $n * 3 ) {
		my $track = _randomTrack( undef, $lib );
		last unless $track;
		next if $skip->{ $track->id };
		next if grep { $_->{trackid} == $track->id } @picked;
		my $tile = _tileFromTrack( $track, undef );
		push @picked, $tile if $tile;
	}

	return @picked;
}

# Random local audio track, optionally within a genre and/or library
sub _randomTrack {
	my ($genreId, $lib) = @_;
	my $dbh = Slim::Schema->dbh;

	my @joins;
	my @where = ( "t.audio = 1", "t.remote = 0", "t.url LIKE 'file:%'", "t.url NOT LIKE '%#%'" );
	my @bind;

	if ( defined $genreId ) {
		push @joins, "JOIN genre_track gt ON gt.track = t.id";
		push @where, "gt.genre = ?";
		push @bind,  $genreId;
	}
	if ( $lib ne '' ) {
		push @joins, "JOIN library_track lt ON lt.track = t.id";
		push @where, "lt.library = ?";
		push @bind,  $lib;
	}

	my $sql = "SELECT t.id FROM tracks t " . join( ' ', @joins ) . " WHERE " . join( ' AND ', @where ) . " ORDER BY RANDOM() LIMIT 1";
	my ($id) = $dbh->selectrow_array( $sql, undef, @bind );
	return undef unless $id;

	my ($track) = Slim::Schema->find( 'Track', $id );
	return $track;
}

sub _tileFromTrack {
	my ($track, $genreId) = @_;

	return undef unless $track && $track->url =~ /^file:/ && $track->url !~ /#/;

	my $genreName = '';
	my $genre = defined $genreId ? Slim::Schema->find( 'Genre', $genreId ) : eval { $track->genre };
	$genreName = $genre->name if $genre;

	return {
		trackid => $track->id,
		title   => $track->title || '',
		artist  => $track->artistName || '',
		genre   => $genreName,
		genreid => $genre ? $genre->id : undef,
		coverid => $track->coverid,
	};
}

# Replace a single tile (after it was played) with a track from a genre that
# is not currently shown in that library's set.
sub _replaceTile {
	my ($lib, $idx) = @_;
	$lib = '' unless defined $lib;

	my $tiles = $tileSets{$lib} or return;
	return unless defined $tiles->[$idx];

	my %exclude = map { $_->{genreid} ? ( $_->{genreid} => 1 ) : () } @$tiles;
	my %tracks  = map { $_->{trackid} => 1 } @$tiles;
	my ($new) = _pickTracks( 1, \%exclude, $lib, \%tracks );
	return unless $new;

	$tiles->[$idx] = $new;

	_signalMaterialRefresh();
	Slim::Control::Request::notifyFromArray(undef, ['blissdiscovery', 'changed']);
}

# ---------------------------------------------------------------------------
# Timers / notifications / CLI
# ---------------------------------------------------------------------------

sub _scheduleTimer {
	Slim::Utils::Timers::killTimers(undef, \&_periodicRefresh);
	my $hours = $prefs->get('refreshHours') || 0;
	return unless $hours > 0;
	Slim::Utils::Timers::setTimer(undef, time() + $hours * 3600, \&_periodicRefresh);
}

sub _periodicRefresh {
	refreshTiles();
	_scheduleTimer();
}

sub _onRescanDone {
	Slim::Utils::Timers::killTimers(undef, \&refreshTiles);
	Slim::Utils::Timers::setTimer(undef, time() + 10, \&refreshTiles);
}

sub _cliRefresh {
	my $request = shift;
	refreshTiles();
	$request->setStatusDone();
}

sub _cliList {
	my $request = shift;
	my $i = 0;
	for my $lib ( sort keys %tileSets ) {
	my $t = 0;
	for my $tile ( @{ $tileSets{$lib} } ) {
		$request->addResultLoop('tiles_loop', $i, 'library', $lib);
		$request->addResultLoop('tiles_loop', $i, 'tile',    $t++);
		$request->addResultLoop('tiles_loop', $i, 'title',   $tile->{title});
		$request->addResultLoop('tiles_loop', $i, 'artist',  $tile->{artist});
		$request->addResultLoop('tiles_loop', $i, 'genre',   $tile->{genre});
		$request->addResultLoop('tiles_loop', $i, 'trackid', $tile->{trackid});
		$request->addResultLoop('tiles_loop', $i, 'coverid', $tile->{coverid});
		$i++;
	}
	}
	$request->addResult('count', $i);
	$request->addResult('librarymode', $prefs->get('library') || '');
	$request->addResult('material', $registeredWithMaterial);
	$request->setStatusDone();
}

1;
