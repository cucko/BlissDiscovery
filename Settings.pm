package Plugins::BlissDiscovery::Settings;

use strict;
use warnings;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;
use Slim::Music::VirtualLibraries;

my $prefs = preferences('plugin.blissdiscovery');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_BLISSDISCOVERY');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/BlissDiscovery/settings/basic.html');
}

sub prefs {
	return ( $prefs, qw(numTiles mixCount dstm refreshAfterPlay refreshHours library genreSource favoriteGenres excludedGenres) );
}

sub handler {
	my ($class, $client, $params) = @_;

	if ( $params->{saveSettings} ) {
		# Unchecked checkboxes are not submitted at all - normalise to 0/1
		$params->{pref_dstm}             = $params->{pref_dstm}             ? 1 : 0;
		$params->{pref_refreshAfterPlay} = $params->{pref_refreshAfterPlay} ? 1 : 0;
	}

	if ( $params->{refreshNow} ) {
		Plugins::BlissDiscovery::Plugin::refreshTiles();
	}

	# How many Bliss Mixer genre groups are defined, so the page can say so
	my $blissGroups = preferences('plugin.blissmixer')->get('genre_groups') || '';
	$params->{blissGroupCount} = scalar grep { /\S/ } split /\n/, $blissGroups;

	# Virtual libraries for the library selector
	my $libs = Slim::Music::VirtualLibraries->getLibraries() || {};
	$params->{libraries} = [
		sort { lc( $a->{name} ) cmp lc( $b->{name} ) }
		map  { { id => $_, name => Slim::Music::VirtualLibraries->getNameForId($_) || $libs->{$_}->{name} || $_ } }
		keys %$libs
	];

	return $class->SUPER::handler($client, $params);
}

1;
