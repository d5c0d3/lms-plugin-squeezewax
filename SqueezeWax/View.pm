package Plugins::SqueezeWax::View;

# The "Records I own" library view: the normal album grid, filtered to the
# albums the ownership pass decided you own.
#
# It is a LIBRARY, not an app (decisions §15.25 ruling 2). A library gets the
# skins' own album grid, their artwork, their sort orders and their menus for
# nothing, in every skin at once, and appears in the library picker beside
# LMS's own views. An app would be a second album browser we would then have to
# keep.
#
# A scannerCB rather than sql, and the reason is the same one Menu.pm has:
# discogs_match.lms_album_id is a cache that nothing refreshes for an album the
# importer skips, so a view built by joining on it would fill with THE WRONG
# ALBUMS after LMS reassigned its ids (plan D1). The callback keys on album_key
# instead, which no renumbering can move.
#
# Registered in the SERVER only. A virtual library can also be rebuilt during a
# scan, at importer weight 100 (Slim/Music/VirtualLibraries.pm, init) - which is
# BEFORE our own scan pass at weight 130, so a scan-time rebuild would always
# describe the ownership of the scan before last. The rebuilds that matter are
# the ones after a completed pass, and those are in the server.

use strict;

use Slim::Menu::BrowseLibrary;
use Slim::Music::Import;
use Slim::Music::VirtualLibraries;
use Slim::Schema;
use Slim::Utils::Log;

use Plugins::SqueezeWax::Library;
use Plugins::SqueezeWax::Schema;

my $log = logger('plugin.squeezewax');

# Ours, and specific to this plugin as registerLibrary's own POD asks. LMS
# stores the first 8 characters of its md5 as the real id, which getRealId maps
# back (Slim/Music/VirtualLibraries.pm, sub registerLibrary / sub getRealId).
use constant LIBRARY_ID => 'squeezewaxOwned';

use constant NODE_ID => 'squeezewaxOwnedAlbums';

=head2 init( )

Register the library and the My Music entry. Server only, from C<initPlugin>.

=cut

sub init {
	my $class = shift;

	# name AND string: registerLibrary takes name as the fallback and
	# localizedLibraryName prefers the string when it exists
	# (VirtualLibraries.pm, sub localizedLibraryName).
	#
	# Registering while a scan is running logs an error from core and registers
	# anyway, skipping only the initial build (registerLibrary's !main::SCANNER
	# branch). That is survivable rather than ideal: the scan ends in a
	# ['rescan','done'], which rebuilds. The one case with no rebuild behind it
	# is a server started during a scan by a user who has never synced, and
	# there is nothing to put in the view then either.
	my $id = Slim::Music::VirtualLibraries->registerLibrary({
		id        => LIBRARY_ID,
		name      => 'Records I own',
		string    => 'PLUGIN_SQUEEZEWAX_LIBRARY_OWNED',
		scannerCB => \&_build,
	});

	if ( !$id ) {
		$log->error('could not register the "Records I own" library view');

		return;
	}

	# D3: without this the only way into the view is switching the player's
	# whole library. The shape is core's own demo's
	# (Slim/Plugin/LibraryDemo/Plugin.pm), including the condition, which is
	# what lets a user hide the node.
	Slim::Menu::BrowseLibrary->registerNode({
		type         => 'link',
		name         => 'PLUGIN_SQUEEZEWAX_LIBRARY_OWNED',
		params       => { library_id => Slim::Music::VirtualLibraries->getRealId(LIBRARY_ID) },
		feed         => \&Slim::Menu::BrowseLibrary::_albums,
		icon         => 'html/images/albums.png',
		jiveIcon     => 'html/images/albums.png',
		homeMenuText => 'PLUGIN_SQUEEZEWAX_LIBRARY_OWNED',
		condition    => \&Slim::Menu::BrowseLibrary::isEnabledNode,
		id           => NODE_ID,
		weight       => 26,
		cache        => 1,
	});

	main::INFOLOG && $log->is_info && $log->info('"Records I own" registered');

	return;
}

=head2 rebuild( )

Rebuild the view from what C<discogs_match> now says. Local SQL only - no
Discogs request, nothing written to our own tables.

Called after a completed ownership pass: from C<API::Async> when
C<Ownership-E<gt>apply> returns C<ok>, and from C<Plugin.pm>'s
C<['rescan','done']> handler and its scan-time-sync skip, which between them
cover the pass that runs inside the scan and a full library wipe.

Refused while a scan is running. The scan holds the write lock, and its own
C<rescan done> brings us back here afterwards.

=cut

sub rebuild {
	my $class = shift;

	return 0 unless Plugins::SqueezeWax::Schema->isReady;

	if ( Slim::Music::Import->stillScanning ) {
		main::INFOLOG && $log->is_info
			&& $log->info('library scan in progress; not rebuilding the owned view');

		return 0;
	}

	my $id = Slim::Music::VirtualLibraries->getRealId(LIBRARY_ID);

	if ( !$id ) {
		main::INFOLOG && $log->is_info
			&& $log->info('the owned view is not registered; nothing to rebuild');

		return 0;
	}

	# rebuild deletes the library's rows and then calls _build (VirtualLibraries
	# rebuild), and goes on to refill library_album and library_contributor from
	# what _build inserted. Never call it in a loop: it is one pass over the
	# owned set.
	Slim::Music::VirtualLibraries->rebuild($id);

	return 1;
}

# The callback, called from INSIDE rebuild with the real library id, after the
# old library_track rows have already been deleted. Its whole job is to insert
# the tracks that belong in the view now.
#
# A plain function per the calling convention, and passed as a coderef to
# registerLibrary, so it is never reached method-style.
sub _build {
	my ($id) = @_;

	my $owned = _ownedKeys();

	if ( !%$owned ) {
		main::INFOLOG && $log->is_info
			&& $log->info('no owned albums; the view is empty');

		return;
	}

	# An empty view is an empty library, not an error: a user with no token has
	# never synced, and "nothing yet" is the honest answer.
	my @albumIds;

	Plugins::SqueezeWax::Library->eachAlbum( sub {
		my $album = shift;

		push @albumIds, $album->{album_id} if $owned->{ $album->{album_key} };

		return 1;
	} );

	my $trackIds = Plugins::SqueezeWax::Library->trackIdsForAlbums( \@albumIds );

	my $dbh = Slim::Schema->dbh;
	my $sth = $dbh->prepare_cached(
		'INSERT OR IGNORE INTO library_track (library, track) VALUES (?, ?)' );

	$sth->execute( $id, $_ ) for @$trackIds;

	main::INFOLOG && $log->is_info
		&& $log->info( 'owned view built: ' . scalar(@albumIds) . ' albums, '
			. scalar(@$trackIds) . ' tracks' );

	return;
}

# The owned keys, as a set. 'exact' and 'version' alike and nothing else
# (design §3, decisions §15.25 ruling 3): no state test, no confirmation test,
# no join against anything Discogs.
#
# A conflict row is NOT excluded here, though it gets no link in the menu. The
# two are different questions: which record this is, and whether the user owns
# the album at all. The pass answered the second one for a conflict row by the
# title route, and an album is no less owned for having two files that disagree
# about the pressing.
sub _ownedKeys {
	my $rows = Slim::Schema->dbh->selectcol_arrayref(q{
		SELECT album_key
		  FROM squeezewax.discogs_match
		 WHERE ownership IN ('exact','version')
	});

	return { map { $_ => 1 } @{ $rows || [] } };
}

1;
