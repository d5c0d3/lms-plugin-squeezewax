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
# What the entry contains, in full: one line saying what you own, and a link to
# the Discogs page where we hold an id. NO DISCOGS DATA - no label, catalogue
# number, format, year, credits or value. That is not an omission to be tidied
# up later: Discogs' terms put "Data provided by Discogs" directly next to any
# Discogs data, and the settings page is where those notices live (decisions
# §9.6, §15.25 ruling 4). Anything from a Discogs payload added below brings the
# notice back into the menu with it.
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
# early when it cannot.
sub _albumInfo {
	my ( $client, $url, $album ) = @_;

	return undef unless $album && $album->can('id');

	return _itemFor( $album->id );
}

# ( $client, $url, $track, $remoteMeta, $tags, $filter ) -
# refs/slimserver/Slim/Menu/TrackInfo.pm, sub menu.
#
# A track with no album is the normal case for a stream that is not in the
# library, and it is the reason this is a separate sub rather than the same one:
# there is nothing to key on, so there is no entry. ->album is the accessor
# TrackInfo's own providers use (sub infoDisc).
sub _trackInfo {
	my ( $client, $url, $track ) = @_;

	return undef unless $track && $track->can('album');

	my $album = $track->album;

	return undef unless $album && $album->can('id');

	return _itemFor( $album->id );
}

# One album id to a menu item, or undef for no entry at all.
#
# The table is decisions §15.25 ruling 3 and 5, and it is deliberately short:
#
#   no row, or ownership 'absent'   nothing
#   exact                           "You own this pressing"
#   version                         "You own a version of this record"
#
# and a link where we have an id to link to. An album we have never looked at,
# and an album we looked at and decided is not in the collection, are the same
# thing to a user, so they look the same here.
sub _itemFor {
	my ($albumId) = @_;

	my $row = _row($albumId) or return undef;

	my $ownership = $row->{ownership} || '';

	return undef unless $ownership eq 'exact' || $ownership eq 'version';

	my $item = {
		type => 'text',
		name => string( $ownership eq 'exact'
			? 'PLUGIN_SQUEEZEWAX_MENU_OWN_PRESSING'
			: 'PLUGIN_SQUEEZEWAX_MENU_OWN_VERSION' ),
	};

	if ( my $link = _link( $row, $ownership ) ) {
		# type 'text' with a weblink, core's own shape
		# (refs/slimserver/Slim/Menu/TrackInfo.pm, sub infoUrl). XMLBrowser
		# passes weblink through verbatim (Slim/Control/XMLBrowser.pm, the
		# $item->{weblink} branch) and the Default UI renders it as
		# <a href target="_blank"> with no rel at all
		# (HTML/Default/xmlbrowser.html, BLOCK weblink) - which is what §9.6
		# needs: no nofollow on a Discogs link, here or anywhere.
		return [
			$item,
			{
				type    => 'text',
				name    => string('PLUGIN_SQUEEZEWAX_MENU_LINK'),
				weblink => $link,
			},
		];
	}

	return $item;
}

# Where the link goes, or undef for a line with no link.
#
# THE LINK DESCRIBES THE ALBUM, NOT THE COPY, and its string says so. A version
# album can reach its ownership by the title route (design §3 node H) while its
# own tags name a release under a DIFFERENT master - and then the master here is
# not the one the user owns. Nothing stored says which node decided, and the
# collection is not kept (§13.2), so the honest label is "This album on
# Discogs", which is true either way. Never "your version" (plan D2).
#
# A conflict row gets no release link whatever its ownership. Its release id is
# not an answer: two of the album's files name different releases, and the row
# is untagged to the ownership pass for exactly that reason (§15.16 part 4,
# §15.22). Offering one of the two as "the" pressing would launder a
# disagreement into a fact.
sub _link {
	my ( $row, $ownership ) = @_;

	my $conflict = ( $row->{review_reason} || '' ) eq 'conflict';

	if ( $ownership eq 'exact' ) {
		return undef if $conflict;

		return undef unless defined $row->{discogs_release_id};

		return RELEASE_URL . $row->{discogs_release_id};
	}

	return undef if $conflict;

	# CALLED, not re-implemented. It is the stale-derivation guard: a derived
	# master is only an answer for the release it was derived FROM, so a
	# retagged album whose release id has moved on gets no master here rather
	# than its old one (Ownership::_effectiveMaster, decisions §15.22).
	my $master = Plugins::SqueezeWax::Ownership::_effectiveMaster($row);

	return defined $master ? MASTER_URL . $master : undef;
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
