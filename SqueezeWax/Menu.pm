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
# What the entry contains, in full (decisions §15.26 as amended by §15.31
# rulings 16-17): an app that can open a weblink (core's canFollowWeblinks) gets
# links, each followed by its own submenu - the release link and "your
# pressing's details" for an exact album, the master link and "master details"
# wherever a master is usable. A version album gets no release link: a link may
# name only a pressing the user owns, and for a version the owned one is not
# stored. A player, and an app with no link to offer, gets one text line saying
# what you own instead, then the submenus. Ownership is never shown as nothing.
#
# NO DISCOGS DATA AT THIS LEVEL. The submenus hold it, and each ends with "Data
# provided by Discogs" next to it (decisions §9.6) - see Details.pm. Anything
# from a Discogs payload added to this level brings the notice with it.
#
# And NO DISCOGS REQUEST when the menu is built. Nothing here may reach API.pm:
# a menu open is a user waiting, the rate budget is one budget for the whole
# process (CLAUDE.md), and a request per menu open would spend it where nobody
# asked. A submenu is a code reference that core calls only when it is opened
# (Slim/Control/XMLBrowser.pm:471-525), one request per open. menu-check.pl
# asserts the menu itself with a transport that dies on any call.
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

use Plugins::SqueezeWax::Details;
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

# One album id to its menu items, or undef for no entry at all.
#
# The table is decisions §15.26 rulings 1-3 as amended by §15.31 rulings 16-17:
#
#   no row, or ownership 'absent'   nothing
#   a link-capable app, >=1 link    the links, each followed by its submenu
#   otherwise (a player, or a       "You own a pressing" (exact) /
#     link-capable app with none)     "You own a version" (version),
#                                     then the submenus
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

	# Default UI template and plain CLI carry no menuMode tag at all
	# (refs/slimserver/Slim/Menu/Base.pm:180, the guard every menuMode
	# provider is checked against) and render as a page rather than on a
	# player, so both are treated as link-capable; so is menu mode with no
	# $client (43). Only a real client in menu mode is asked.
	my $linkCapable = !$tags->{menuMode}
		|| !$client
		|| Slim::Utils::Misc::canFollowWeblinks($client);

	my @entries = _entries( $row, $ownership, $linkCapable ? 1 : 0 );

	if ( $linkCapable && grep { $_->{weblink} } @entries ) {
		return \@entries;
	}

	return [
		{
			type => 'text',
			name => string( $ownership eq 'exact'
				? 'PLUGIN_SQUEEZEWAX_MENU_OWN_PRESSING'
				: 'PLUGIN_SQUEEZEWAX_MENU_OWN_VERSION' ),
		},
		grep { !$_->{weblink} } @entries,
	];
}

# The four rows of §15.31 ruling 16, in that order, each only where it applies:
#
#   1  the release link          exact, a release id
#   2  your pressing's details   exact, a release id
#   3  the master link           a usable master
#   4  master details            a usable master
#
# The links are type 'text' with a weblink, core's own shape
# (refs/slimserver/Slim/Menu/TrackInfo.pm, sub infoUrl). XMLBrowser passes
# weblink through verbatim (Slim/Control/XMLBrowser.pm:1153-1154) and the
# Default UI renders it as <a href target="_blank"> with no rel at all
# (HTML/Default/xmlbrowser.html, BLOCK weblink) - which is what §9.6 needs: no
# nofollow on a Discogs link, here or anywhere. The caller drops the links for
# an app that cannot open them.
#
# The submenus are core's "View tags" shape (Slim/Menu/TrackInfo.pm:1259-1274,
# infoTagDump): a code reference, its arguments in passthrough, isContextMenu.
# Nothing is fetched until core calls it. The passthrough carries this menu's
# link-capability answer too, so Details.pm tells a player apart by exactly the
# test that decided whether it got links.
#
# A VERSION ALBUM GETS NO RELEASE LINK AND NO RELEASE DETAILS (§15.31 ruling 17,
# ruling 1). Its release id names what the files carry, which is not the copy
# owned, and the owned one is not stored (§13.2). The master is a different
# matter: owning any version of it is what `version` means.
#
# A conflict row gets NOTHING, whatever its ownership. Its release id is not an
# answer: two of the album's files name different releases, and the row is
# untagged to the ownership pass for exactly that reason (§15.16 part 4,
# §15.22). Offering one of the two as "the" pressing would launder a
# disagreement into a fact - and the master it would lead to is the master of
# one of the two (§15.31 ruling 3).
sub _entries {
	my ( $row, $ownership, $linkCapable ) = @_;

	return () if ( $row->{review_reason} || '' ) eq 'conflict';

	my @entries;

	my $release = $row->{discogs_release_id};

	if ( $ownership eq 'exact' && defined $release ) {
		push @entries, {
			type    => 'text',
			name    => string('PLUGIN_SQUEEZEWAX_MENU_LINK_OWNED'),
			weblink => RELEASE_URL . $release,
		}, {
			name          => string('PLUGIN_SQUEEZEWAX_MENU_DETAILS_RELEASE'),
			url           => \&Plugins::SqueezeWax::Details::_releaseDetails,
			passthrough   => [ $release, $linkCapable ],
			isContextMenu => 1,
		};
	}

	# CALLED, not re-implemented. It is the stale-derivation guard: a derived
	# master is only an answer for the release it was derived FROM, so a
	# retagged album whose release id has moved on gets no master here rather
	# than its old one (Ownership::_effectiveMaster, decisions §15.22).
	my $master = Plugins::SqueezeWax::Ownership::_effectiveMaster($row);

	if ( defined $master ) {
		push @entries, {
			type    => 'text',
			name    => string('PLUGIN_SQUEEZEWAX_MENU_LINK_MASTER'),
			weblink => MASTER_URL . $master,
		}, {
			name          => string('PLUGIN_SQUEEZEWAX_MENU_DETAILS_MASTER'),
			url           => \&Plugins::SqueezeWax::Details::_masterDetails,
			passthrough   => [ $master, $linkCapable ],
			isContextMenu => 1,
		};
	}

	return @entries;
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
