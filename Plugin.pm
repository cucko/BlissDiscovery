package Plugins::BlissDiscovery::Plugin;

#
# Bliss Discovery - adds a "Bliss Discovery" section to the Material Skin home screen.
# Each tile shows the artwork of a randomly chosen track, every tile from a
# different genre. Clicking a tile starts a Bliss mix seeded from that track
# (via the Bliss Mixer plugin's "blissmixer mix" command).
#

use strict;
use warnings;
use base qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Timers;
use Slim::Control::Request;
use Slim::Music::VirtualLibraries;
use List::Util ();

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

# The library id Material Skin uses for "All tracks" in its Change Library dialog
use constant MATERIAL_ALL_LIB => '-1';

# Tile sets, keyed by library id ('' = whole library). Each value is an
# arrayref of tiles: { trackid, title, artist, genre, genreid, coverid, bucket }
# 'bucket' is the genre slot the tile occupies - an LMS genre or a Bliss Mixer
# genre group, depending on the genreSource setting - so that no two tiles in
# a set share one.
my %tileSets = ();

# Bliss Mixer's genre groups resolved to LMS genre ids, rebuilt on each tile
# refresh (see _blissGenreGroups)
my $blissGroups;
my $registeredWithMaterial = 0;

# Library last chosen with Material Skin's "Change Library" button, keyed by
# player id; the '' key holds the most recent value seen from any browser and
# is used when we have no player.
my %materialLibrary = ();

# Material Skin's own 'material-skin' CLI handler, which we chain in front of
my $materialCliChain;

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
		library          => '',     # '' = all music, 'material' = Material Skin's Change Library, 'player' = player's library view, else a virtual library id
		genreSource      => 'lms',  # 'lms' = one tile per LMS genre, 'bliss' = one tile per Bliss Mixer genre group
	});

	$prefs->setValidate({ validator => 'intlimit', low => 1, high => MAX_TILES }, 'numTiles');
	$prefs->setValidate({ validator => 'intlimit', low => 1, high => 50 },        'mixCount');
	$prefs->setValidate({ validator => 'intlimit', low => 0, high => 720 },       'refreshHours');

	$prefs->setChange(sub { refreshTiles(); },   'numTiles');
	$prefs->setChange(sub { refreshTiles(); },   'genreSource');
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

	# Adds a "Bliss Discovery" entry to the "My Apps" menu (Default/Touch web
	# skin, Jive/SqueezePlay-based UIs, ...) - tapping it lists the current
	# tiles and starts a Bliss mix from whichever one is selected.
	$class->SUPER::initPlugin(
		feed   => \&_appMenu,
		tag    => 'blissdiscovery',
		menu   => 'apps',
		weight => 50,
		is_app => 1,
	);
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
	_unhookMaterialCli();
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

	_hookMaterialCli();

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

# Material Skin keeps the library picked with its "Change Library" button in the
# browser, and only sends it along as a 'library_id' parameter on the requests
# that browser makes - it is not part of the arguments a home-extra handler is
# given. So chain ourselves in front of Material's own CLI handler and note the
# value as it goes past.
sub _hookMaterialCli {
	return if $materialCliChain;

	# addDispatch hands back the function it replaced, so that a new entry can
	# call the old one.
	my $prev = Slim::Control::Request::addDispatch(
		[ 'material-skin', '_cmd' ], [ 0, 0, 1, \&_materialCliHook ]
	);

	if ( !$prev ) {
		$log->warn('Could not chain the Material Skin CLI handler - its selected library will not be seen');
		return;
	}

	$materialCliChain = $prev;
	main::INFOLOG && $log->info("Watching Material Skin's requests for the selected library");
}

sub _unhookMaterialCli {
	return unless $materialCliChain;
	Slim::Control::Request::addDispatch( [ 'material-skin', '_cmd' ], [ 0, 0, 1, $materialCliChain ] );
	$materialCliChain = undef;
}

sub _materialCliHook {
	my $request = shift;

	if ( ( $request->getParam('_cmd') || '' ) eq 'home-extra' ) {
		my $lib = $request->getParam('library_id');

		# Only the home screen sends library_id; the section's "More" page does
		# not, so leave the last known value alone when it is missing.
		if ( defined $lib && $lib ne '' ) {
			$lib = '' if $lib eq MATERIAL_ALL_LIB;
			$lib = '' unless $lib eq '' || Slim::Music::VirtualLibraries->getRealId($lib);

			my $client = $request->client;
			$materialLibrary{''} = $lib;
			$materialLibrary{ $client->id } = $lib if $client;
		}
	}

	$materialCliChain->( $request, @_ );
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

# ---------------------------------------------------------------------------
# "My Apps" menu (Slim::Plugin::OPMLBased feed - Default/Touch skin, Jive/
# SqueezePlay-based UIs, and any other client that browses the apps menu)
# ---------------------------------------------------------------------------

# One item per current tile, plus a "Regenerate" action. Each item's `url` is
# a sub that runs the same CLI command the Material Skin home-screen section
# uses - `url` (drill-down) is used rather than a bare `actions.go`, since
# that is the one selection mechanism every OPML client (Default/Touch web
# skin, Jive/SqueezePlay, Material's own apps browser, Squeezer, ...) is
# guaranteed to invoke when an item is picked. Each item's own `nextWindow`
# (not the url handler's response - that's too late, the client has already
# navigated by then) tells the client what to do once url resolves. This
# has to be 'refresh' (re-fetch this same list via _appMenu), not 'parent'
# (which pops past this list back to whatever showed it, e.g. "My Apps") -
# tapping a tile must leave the client on the Bliss Discovery list.
# Unlike the Material home row (capped to "Number of tiles" tiles), the My
# Apps menu isn't space constrained, so it shows the full expanded set - the
# same one Material's "More" button would reveal.
sub _appMenu {
	my ($client, $cb, $args) = @_;

	my $lib      = _effectiveLibrary($client);
	my $numTiles = $prefs->get('numTiles') || 6;
	my $tiles    = _tilesFor( $lib, $numTiles * MORE_FACTOR );

	my @items;

	for my $i ( 0 .. $#$tiles ) {
		my $tile = $tiles->[$i];
		my $name = $tile->{title};
		$name .= ' - ' . $tile->{artist} if $tile->{artist};
		$name .= " ($tile->{genre})" if $tile->{genre};

		push @items, {
			name       => $name,
			icon       => $tile->{coverid} ? "music/$tile->{coverid}/cover.jpg" : 'MTL_icon_auto_awesome',
			type       => 'link',
			url        => sub { _appMenuPlay( $i, $lib, @_ ); },
			# Tells the client what to do once url resolves, instead of
			# pushing/showing the (empty) window it returns - same convention
			# as the Regenerate item below (and the Material home row).
			nextWindow => 'refresh',
		};
	}

	push @items, {
		name       => string('PLUGIN_BLISSDISCOVERY_REGENERATE'),
		icon       => 'MTL_icon_refresh',
		type       => 'link',
		url        => \&_appMenuRefresh,
		nextWindow => 'refresh',
	};

	$cb->({
		items  => \@items,
		offset => 0,
		count  => scalar @items,
	});
}

# Selecting a tile: run the same "blissdiscovery playlist play" CLI command
# the Material Skin section uses (so DSTM and tile replacement still happen),
# then stay on the tile list - nothing new is shown, the mix just starts on
# the current player.
sub _appMenuPlay {
	my ($idx, $lib, $client, $cb, $args) = @_;

	if ( !$client ) {
		$cb->({ items => [], nextWindow => 'refresh' });
		return;
	}

	my @cmd = ( 'blissdiscovery', 'playlist', 'play', "tile:$idx" );
	push @cmd, "lib:$lib" if $lib ne '';

	my $req = Slim::Control::Request::executeRequest( $client, \@cmd );

	my $respond = sub {
		$cb->({ items => [], nextWindow => 'refresh' });
	};

	if ( $req && $req->isStatusProcessing ) {
		$req->callbackFunction($respond);
	}
	else {
		$respond->();
	}
}

# "Regenerate": re-pick all tiles, then have the client re-fetch this same
# list (via _appMenu) so it redraws with the new tiles rather than pushing a
# new screen.
sub _appMenuRefresh {
	my ($client, $cb, $args) = @_;
	refreshTiles();
	$cb->({ items => [], nextWindow => 'refresh' });
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
	%tileSets    = ();
	$blissGroups = undef;
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

	# Library picked with Material Skin's "Change Library" button, as last seen
	# on a home-screen request from that browser.
	if ( $pref eq 'material' ) {
		my $lib = ( $client && defined $materialLibrary{ $client->id } )
			? $materialLibrary{ $client->id }
			: $materialLibrary{''};

		return '' unless defined $lib && $lib ne '';
		return Slim::Music::VirtualLibraries->getRealId($lib) || '';
	}

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
		my %buckets = map { $_->{bucket} ? ( $_->{bucket} => 1 ) : () } @$tiles;
		my %tracks  = map { $_->{trackid} => 1 } @$tiles;

		push @$tiles, _pickTracks( $want - @$tiles, \%buckets, $lib, \%tracks );
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

# Pick up to $n tracks, each from a different bucket (see _buckets). $exclude
# is a hashref of bucket keys that must not be used (it is updated with the
# ones taken), $skip an optional hashref of track ids to leave out. $lib
# restricts to a virtual library.
sub _pickTracks {
	my ($n, $exclude, $lib, $skip) = @_;
	$lib  = '' unless defined $lib;
	$skip = {} unless defined $skip;

	my @picked;

	for my $bucket ( _buckets($lib) ) {
		last if @picked >= $n;
		next if $exclude->{ $bucket->{key} };

		my ($track, $genreId) = _randomTrack( $bucket->{genreids}, $lib );
		next unless $track;
		next if $skip->{ $track->id };

		my $tile = _tileFromTrack( $track, $genreId, $bucket->{key} );
		next unless $tile;

		push @picked, $tile;
		$exclude->{ $bucket->{key} } = 1;
	}

	# Not enough buckets with usable tracks: fill up with random tracks.
	my $guard = 0;
	while ( @picked < $n && $guard++ < $n * 3 ) {
		my ($track) = _randomTrack( undef, $lib );
		last unless $track;
		next if $skip->{ $track->id };
		next if grep { $_->{trackid} == $track->id } @picked;
		my $tile = _tileFromTrack( $track, undef, undef );
		push @picked, $tile if $tile;
	}

	return @picked;
}

# The genre slots tiles are drawn from, in random order. Each is
# { key => <unique string>, genreids => [ LMS genre ids ] }.
# With genreSource 'lms' every genre that has tracks in the library is a
# bucket; with 'bliss' every Bliss Mixer genre group is one.
sub _buckets {
	my $lib = shift;
	my $dbh = Slim::Schema->dbh;

	if ( ( $prefs->get('genreSource') || 'lms' ) eq 'bliss' ) {
		my $groups = _blissGenreGroups();

		if ( @$groups ) {
			return List::Util::shuffle(
				map { { key => "b$_", genreids => $groups->[$_]->{genreids} } }
				grep { @{ $groups->[$_]->{genreids} } } 0 .. $#$groups
			);
		}

		$log->warn('Bliss Mixer has no genre groups defined - using LMS genres instead');
	}

	my $sql = $lib ne ''
		? "SELECT DISTINCT gt.genre FROM genre_track gt JOIN library_track lt ON lt.track = gt.track WHERE lt.library = ? ORDER BY RANDOM()"
		: "SELECT id FROM genres ORDER BY RANDOM()";

	return map { { key => "g$_->[0]", genreids => [ $_->[0] ] } }
		@{ $dbh->selectall_arrayref( $sql, undef, ( $lib ne '' ? ($lib) : () ) ) || [] };
}

# Bliss Mixer's genre groups (Settings > Bliss Mixer > Genre groups), resolved
# to LMS genre ids: [ { name => 'Rock; Metal', genreids => [...] }, ... ].
# Mirrors how Bliss Mixer reads its own setting: one group per line, names
# separated by ';', each name a case-insensitive glob ('* Rock', 'Pop', ...).
# With Bliss's "use track genre" option on, every genre not covered by a group
# becomes a group of its own, as it does for Bliss's filtering.
sub _blissGenreGroups {
	return $blissGroups if $blissGroups;

	my $bliss  = preferences('plugin.blissmixer');
	my $dbh    = Slim::Schema->dbh;
	my @genres = @{ $dbh->selectall_arrayref("SELECT id, name FROM genres WHERE name IS NOT NULL") || [] };

	my @groups;
	my %covered;

	for my $line ( split /\n/, ( $bliss->get('genre_groups') || '' ) ) {
		my @names;
		for my $name ( split /;/, $line ) {
			$name =~ s/^\s+//;
			$name =~ s/\s+$//;
			push @names, $name if length $name;
		}
		next unless @names;

		my %ids;
		for my $name (@names) {
			my $re = _globToRegex($name);
			for my $g (@genres) {
				next unless lc( $g->[1] ) =~ $re;
				$ids{ $g->[0] } = 1;
				$covered{ $g->[0] } = 1;
			}
		}

		push @groups, { name => join( '; ', @names ), genreids => [ sort { $a <=> $b } keys %ids ] };
	}

	if ( $bliss->get('use_track_genre') ) {
		push @groups, map { { name => $_->[1], genreids => [ $_->[0] ] } }
			grep { !$covered{ $_->[0] } } @genres;
	}

	main::INFOLOG && $log->info( sprintf( 'Resolved %d Bliss genre group(s), %d with matching LMS genres',
		scalar @groups, scalar grep { @{ $_->{genreids} } } @groups ) );

	return $blissGroups = \@groups;
}

# Case-insensitive regex for a Bliss genre-group glob: * ? [...] {a,b}
sub _globToRegex {
	my $glob = lc shift;
	my $re   = '';

	while ( $glob =~ /\G(\*|\?|\[!?[^\]]*\]|\{[^}]*\}|[^*?\[{]+)/gc ) {
		my $t = $1;
		if    ( $t eq '*' )  { $re .= '.*' }
		elsif ( $t eq '?' )  { $re .= '.' }
		elsif ( $t =~ /^\[/ ) { ( my $c = $t ) =~ s/^\[!/[^/; $re .= $c }
		elsif ( $t =~ /^\{(.*)\}$/ ) { $re .= '(?:' . join( '|', map { quotemeta } split /,/, $1 ) . ')' }
		else                 { $re .= quotemeta $t }
	}
	# anything left over (e.g. an unclosed bracket) is taken literally
	$re .= quotemeta substr( $glob, pos($glob) || 0 );

	my $compiled = eval { qr/^$re$/ };
	return $compiled || qr/^\Q$glob\E$/;
}

# Random local audio track, optionally within a set of genres and/or a library.
# Returns ($track, $genreId) - the genre id is the one that qualified the track
# (undef when no genres were given).
# Cue-sheet sub-tracks (url 'file:...#<start>-<end>') are included - both
# bliss-analyser and Bliss Mixer handle them.
sub _randomTrack {
	my ($genreIds, $lib) = @_;
	my $dbh = Slim::Schema->dbh;

	my @joins;
	my @where  = ( "t.audio = 1", "t.remote = 0", "t.url LIKE 'file:%'" );
	my @bind;
	my $select = "t.id, NULL";

	if ( $genreIds && @$genreIds ) {
		push @joins, "JOIN genre_track gt ON gt.track = t.id";
		push @where, "gt.genre IN (" . join( ',', ('?') x @$genreIds ) . ")";
		push @bind,  @$genreIds;
		$select = "t.id, gt.genre";
	}
	if ( $lib ne '' ) {
		push @joins, "JOIN library_track lt ON lt.track = t.id";
		push @where, "lt.library = ?";
		push @bind,  $lib;
	}

	my $sql = "SELECT $select FROM tracks t " . join( ' ', @joins ) . " WHERE " . join( ' AND ', @where ) . " ORDER BY RANDOM() LIMIT 1";
	my ($id, $genreId) = $dbh->selectrow_array( $sql, undef, @bind );
	return unless $id;

	my ($track) = Slim::Schema->find( 'Track', $id );
	return ( $track, $genreId );
}

sub _tileFromTrack {
	my ($track, $genreId, $bucket) = @_;

	return undef unless $track && $track->url =~ /^file:/;

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
		bucket  => $bucket,
	};
}

# Replace a single tile (after it was played) with a track from a bucket that
# is not currently shown in that library's set.
sub _replaceTile {
	my ($lib, $idx) = @_;
	$lib = '' unless defined $lib;

	my $tiles = $tileSets{$lib} or return;
	return unless defined $tiles->[$idx];

	my %exclude = map { $_->{bucket} ? ( $_->{bucket} => 1 ) : () } @$tiles;
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
		$request->addResultLoop('tiles_loop', $i, 'bucket',  $tile->{bucket});
		$request->addResultLoop('tiles_loop', $i, 'trackid', $tile->{trackid});
		$request->addResultLoop('tiles_loop', $i, 'coverid', $tile->{coverid});
		$i++;
	}
	}
	$request->addResult('count', $i);
	$request->addResult('librarymode', $prefs->get('library') || '');
	$request->addResult('genresource', $prefs->get('genreSource') || 'lms');
	$request->addResult('materiallibrary', defined $materialLibrary{''} ? $materialLibrary{''} : '');
	$request->addResult('material', $registeredWithMaterial);
	$request->setStatusDone();
}

1;
