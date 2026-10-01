package Plugins::SqueezeWax::Menu;

# Ownership in the album menu, and in the playing track's menu.
#
# This is where a v1 user first sees that SqueezeWax knows anything at all. It
# is NOT the badge design §4 describes: no skin lets a plugin draw on album
# artwork. Each draws exactly one cover icon, keyed on albums.extid and meaning
# "which service this album came from", and writing our own extid would break
# the album (decisions §15.25). A menu entry and a library view are what IS
# skin-independent, so that is what v1 ships.
#
# What the entry contains, in full (decisions §15.26): an app that can open a
# weblink (core's canFollowWeblinks) gets links only - to the release and to the
# master, each only where its id is stored; a player, and an app with no link to
# offer, gets one text line saying what you own instead. Ownership is never
# shown as nothing. NO DISCOGS DATA - no label, catalogue number, format, year,
# credits or value. That is not an omission to be tidied up later: Discogs'
# terms put "Data provided by Discogs" directly next to any Discogs data, and
# the settings page is where those notices live (decisions §9.6, §15.25 ruling
# 4). Anything from a Discogs payload added below brings the notice back into
# the menu with it.
#
# And NO DISCOGS REQUEST. Nothing here may reach API.pm: a menu open is a user
# waiting, the rate budget is one budget for the whole process (CLAUDE.md), and
# a request per menu open would spend it where nobody asked. menu-check.pl
# asserts it with a transport that dies on any call.
#
# Identity is album_key, never discogs_match.lms_album_id - see
# Library::albumKey for why the id cannot be trusted.

use strict;

use Slim::Menu::AlbumInfo;
use Slim::Menu::TrackInfo;
use Slim::Schema;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string);

use Plugins::SqueezeWax::Library;
use Plugins::SqueezeWax::Ownership;
use Plugins::SqueezeWax::Schema;

my $log = logger('plugin.squeezewax');

# The public pages, not the API. Descriptive labels only, and never the logo or
# the "D" logomark (design §1, the Application Name and Description Policy).
#
# The master form is INFERRED from the uri fields in captured payloads, which
# spell it /master/{id}-{slug}; the release form's redirect from the bare id is
# observed (§15.16). Both are hardware checks (plan §7.1).
use constant RELEASE_URL => 'https://www.discogs.com/release/';
use constant MASTER_URL  => 'https://www.discogs.com/master/';

=head2 init( )

Register both providers. Server only - the scanner has no menus, and
C<Plugin.pm> is never loaded there anyway
(C<refs/slimserver/Slim/Utils/PluginManager.pm>, C<load_plugin>).

C<after =E<gt> 'playitem'> in both menus, the anchor
C<Slim/Plugin/Favorites/Plugin.pm> uses for the same pair
(C<registerInfoProvider>, C<refs/slimserver/Slim/Menu/Base.pm>). Registering
twice replaces our own entry rather than adding a second: the providers are
keyed by name (C<%infoProvider>).

=cut

sub init {
	my $class = shift;

	Slim::Menu::AlbumInfo->registerInfoProvider( squeezewax => (
		after => 'playitem',
		func  => \&_albumInfo,
	) );

	Slim::Menu::TrackInfo->registerInfoProvider( squeezewax => (
		after => 'playitem',
		func  => \&_trackInfo,
	) );

	main::INFOLOG && $log->is_info && $log->info('ownership menu registered');

	return;
}

# ( $client, $url, $album, $remoteMeta, $tags, $filter ) -
# refs/slimserver/Slim/Menu/AlbumInfo.pm, sub menu. $album is always blessed by
# the time a provider runs: menu() inflates it from the url first and returns
# early when it cannot. $client and $tags decide link-capability below -
# neither is used to look the row up.
sub _albumInfo {
	my ( $client, $url, $album, $remoteMeta, $tags ) = @_;

	return undef unless $album && $album->can('id');

	return _itemFor( $client, $tags, $album->id );
}

# ( $client, $url, $track, $remoteMeta, $tags, $filter ) -
# refs/slimserver/Slim/Menu/TrackInfo.pm, sub menu.
#
# A track with no album is the normal case for a stream that is not in the
# library, and it is the reason this is a separate sub rather than the same one:
# there is nothing to key on, so there is no entry. ->album is the accessor
# TrackInfo's own providers use (sub infoDisc).
sub _trackInfo {
	my ( $client, $url, $track, $remoteMeta, $tags ) = @_;

	return undef unless $track && $track->can('album');

	my $album = $track->album;

	return undef unless $album && $album->can('id');

	return _itemFor( $client, $tags, $album->id );
}

# One album id to a menu item, or undef for no entry at all.
#
# The table is decisions §15.26 rulings 1-3, and it is deliberately short:
#
#   no row, or ownership 'absent'   nothing
#   a link-capable app, >=1 link    the link(s) only
#   otherwise (a player, or a       "You own a pressing" (exact) /
#     link-capable app with none)     "You own a version" (version)
#
# An album we have never looked at, and an album we looked at and decided is
# not in the collection, are the same thing to a user, so they look the same
# here. Ownership is never shown as nothing: the text line is the fallback for
# every case a link cannot cover.
sub _itemFor {
	my ( $client, $tags, $albumId ) = @_;

	my $row = _row($albumId) or return undef;

	my $ownership = $row->{ownership} || '';

	return undef unless $ownership eq 'exact' || $ownership eq 'version';

	my @links = _links( $row, $ownership );

	# Default UI template and plain CLI carry no menuMode tag at all
	# (refs/slimserver/Slim/Menu/Base.pm:180, the guard every menuMode
	# provider is checked against) and render as a page rather than on a
	# player, so both are treated as link-capable; so is menu mode with no
	# $client (43). Only a real client in menu mode is asked.
	my $linkCapable = !$tags->{menuMode}
		|| !$client
		|| Slim::Utils::Misc::canFollowWeblinks($client);

	if ( $linkCapable && @links ) {
		return \@links;
	}

	return {
		type => 'text',
		name => string( $ownership eq 'exact'
			? 'PLUGIN_SQUEEZEWAX_MENU_OWN_PRESSING'
			: 'PLUGIN_SQUEEZEWAX_MENU_OWN_VERSION' ),
	};
}

# The release link, then the master link, in that order - each only where its
# id is stored and the row is not contested. Both are type 'text' with a
# weblink, core's own shape (refs/slimserver/Slim/Menu/TrackInfo.pm, sub
# infoUrl). XMLBrowser passes weblink through verbatim
# (Slim/Control/XMLBrowser.pm, the $item->{weblink} branch) and the Default UI
# renders it as <a href target="_blank"> with no rel at all
# (HTML/Default/xmlbrowser.html, BLOCK weblink) - which is what §9.6 needs: no
# nofollow on a Discogs link, here or anywhere.
#
# THE RELEASE LINK DESCRIBES WHAT THE FILES NAME, NOT NECESSARILY THE COPY
# OWNED. A version album can reach its ownership by the title route (design §3
# node H) while its own tags name a release under a DIFFERENT master - so for
# a version, the label says "the pressing your files name", never "your
# pressing" (decisions §15.26 ruling 2).
#
# A conflict row gets NEITHER link, whatever its ownership. Its release id is
# not an answer: two of the album's files name different releases, and the row
# is untagged to the ownership pass for exactly that reason (§15.16 part 4,
# §15.22). Offering one of the two as "the" pressing would launder a
# disagreement into a fact.
sub _links {
	my ( $row, $ownership ) = @_;

	return () if ( $row->{review_reason} || '' ) eq 'conflict';

	my @links;

	if ( defined $row->{discogs_release_id} ) {
		push @links, {
			type    => 'text',
			name    => string( $ownership eq 'exact'
				? 'PLUGIN_SQUEEZEWAX_MENU_LINK_OWNED'
				: 'PLUGIN_SQUEEZEWAX_MENU_LINK_FILES' ),
			weblink => RELEASE_URL . $row->{discogs_release_id},
		};
	}

	# CALLED, not re-implemented. It is the stale-derivation guard: a derived
	# master is only an answer for the release it was derived FROM, so a
	# retagged album whose release id has moved on gets no master here rather
	# than its old one (Ownership::_effectiveMaster, decisions §15.22).
	my $master = Plugins::SqueezeWax::Ownership::_effectiveMaster($row);

	if ( defined $master ) {
		push @links, {
			type    => 'text',
			name    => string('PLUGIN_SQUEEZEWAX_MENU_LINK_MASTER'),
			weblink => MASTER_URL . $master,
		};
	}

	return @links;
}

# One SELECT by album_key. Read-only, and read once per menu open - never per
# grid tile (design §382).
#
# Returns nothing rather than dying when the database is not ready: a menu is
# not the place to learn that squeezewax.db failed to attach, and
# Schema::postDBConnect has already logged why.
sub _row {
	my ($albumId) = @_;

	return undef unless Plugins::SqueezeWax::Schema->isReady;

	my $key = Plugins::SqueezeWax::Library->albumKey($albumId) or return undef;

	my $row = eval {
		Slim::Schema->dbh->selectrow_hashref( q{
			SELECT ownership, review_reason, discogs_release_id, discogs_master_id,
			       derived_master_id, derived_from_release_id
			  FROM squeezewax.discogs_match
			 WHERE album_key = ?
		}, undef, $key );
	};

	if ($@) {
		$log->error("could not read ownership for album $albumId: $@");

		return undef;
	}

	return $row;
}

1;
