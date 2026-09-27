package Plugins::SqueezeWax::ScanSync;

# The scan-time collection sync: build-order step 8b, decisions §15.18.
#
# A second `post` importer of ours, after identification (Importer.pm, weight
# 120). It fetches the Discogs collection with API/Sync.pm and hands it to the
# same ownership pass the server's sync uses, so that when a scan finishes the
# badges are already right (§15.18 part 1). The server's sync after
# ['rescan','done'] survives as the fallback for scans this did not run in, and
# skips itself when this did (Plugin::_syncTick, §15.18 part 8).
#
# Registered from Importer::initPlugin, not from install.xml: the scanner loads
# only the <importmodule> class (Slim/Utils/PluginManager.pm:204, :207), and
# Slim/Plugin/OnlineLibrary/Importer.pm:30-35 and :41-46 register two post
# importers from one initPlugin. %Importers is keyed by class name
# (Slim/Music/Import.pm:551-556), so ours are two entries with two `use` gates.
#
# A failure here is LOGGED ONLY (§15.18 part 3): nothing on the settings page,
# nothing on the queue page, no marker. The fallback then syncs a minute after
# the scan, and records its own error if it fails the same way.

use strict;

use Time::HiRes ();

use Slim::Music::Import;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Progress;

use Plugins::SqueezeWax::API::Sync;
use Plugins::SqueezeWax::Library;
use Plugins::SqueezeWax::Ownership;
use Plugins::SqueezeWax::Schema;

my $log   = logger('plugin.squeezewax');
my $prefs = preferences('plugin.squeezewax');

sub startScan { if (main::SCANNER) {
	my $class = shift;

	# Nothing escapes. runScanPostProcessing runs inside one eval
	# (scanner.pl:348), so a die here would skip the artwork importers, the
	# artwork precache, optimizeDB and afterScan's 'end' notice - the rest of
	# the user's scan, over a Discogs problem. Every failure is caught, logged
	# at error, and returns 0.
	#
	# endImporter exactly once, whatever happened, and only here: without it
	# runImporter's "Starting ... scan" has no "Completed ... Scan", which is
	# the thing Importer.pm's own early returns exist to prevent. The abort
	# path is the one exception, as it is for Importer.pm: an abort exits from
	# inside $progress->update, and SQLiteHelper writes its own row.
	my $progress;

	my $changes = eval { _run( $class, \$progress ) };

	if ( !defined $changes ) {
		my $err = $@ || 'unknown error';
		chomp $err;

		$log->error("scan-time collection sync died: $err");

		_final($progress);

		$changes = 0;
	}

	Slim::Music::Import->endImporter($class);

	return $changes;
} }

sub _run {
	my ( $class, $progressRef ) = @_;

	# 1. The mode. A playlist-only rescan changes no album, so calling Discogs
	# would be waste; an online-library-only rescan adds exactly the all-remote
	# albums only the pass can badge (§15.11), so it is the one mode where
	# skipping would lose badges (§15.18 part 16). The post-processing loop
	# filters neither (Slim/Music/Import.pm:452-459), so the mode is read here.
	#
	# From scanner.pl's own flags (:112, :129-130), not Import's: Import's
	# scanPlaylistsOnly / scanOnlineLibraryOnly are reset at
	# Slim/Music/Import.pm:409-410, before post-processing runs, so by the time
	# this is called they say nothing.
	{
		no warnings 'once';

		if ($main::playlists) {
			main::INFOLOG && $log->is_info
				&& $log->info('playlist-only rescan; no collection sync');

			return 0;
		}
	}

	# 2. The gates. The token is belt and braces behind the `use` gate, as
	# Importer.pm re-checks its tag names. A schema that is not ready would make
	# _writeOk refuse the pass anyway, and finding that out after four requests
	# is the expensive way.
	my $token = $prefs->get('discogsToken');

	if ( !defined $token || $token eq '' ) {
		main::INFOLOG && $log->is_info
			&& $log->info('no Discogs token configured; no scan-time collection sync');

		return 0;
	}

	if ( !Plugins::SqueezeWax::Schema->isReady ) {
		$log->error( 'skipping the scan-time collection sync: '
			. ( Plugins::SqueezeWax::Schema->lastError || 'squeezewax.db is not usable' ) );

		return 0;
	}

	# 3. One progress row for both halves (§15.18 part 12): the fetch ticks per
	# request, the pass per album. The fetch is the slow part - 2.72 s measured
	# against the pass's 40-48 ms - so a row for the pass alone would show a
	# flicker and hide the wait.
	#
	# Created with no total: the page count is not known until the first
	# collection page answers. Progress allows the total to be set later
	# (Slim/Utils/Progress.pm:154-170); how the scan UI and the Material skin
	# render a row whose total is 0 and then changes is UNVERIFIED (plan §7
	# check 4). No `every`, for Importer.pm's reason: the table write and the
	# server notification share one 5-second throttle (:221-245).
	my $progress = $$progressRef = Slim::Utils::Progress->new( {
		type => 'importer',
		name => 'plugin_squeezewax_ownership',
	} );

	# 4. The visibility commit, Importer.pm's (its :165 comment has the whole
	# story): the scan UI reads the progress TABLE, and our write to it is
	# uncommitted until something commits. Here there is a second reason: that
	# write opened the scanner's transaction, and SQLite's
	# sqlite_use_immediate_transaction (Slim/Utils/SQLiteHelper.pm:358) makes it
	# BEGIN IMMEDIATE - so without this commit the write lock would be held
	# across the whole blocking fetch (inferred, not observed).
	Slim::Schema->forceCommit;

	# 5. The fetch, ticking the row once per answered request. Once the page
	# count is known the total becomes every request plus every album: one
	# identity lookup, the pages, and the pass's walk.
	my $albums  = Plugins::SqueezeWax::Library->albumCount;
	my $started = Time::HiRes::time();
	my $totalSet;

	my $fetch = Plugins::SqueezeWax::API::Sync->fetch( $token, sub {
		my ( $requests, $pages ) = @_;

		if ( defined $pages && !$totalSet ) {
			$progress->total( 1 + $pages + $albums );
			$totalSet = 1;
		}

		# An abort point: between requests, before anything is written. There
		# is none INSIDE a blocking request, so abort latency during the fetch
		# is the request time plus up to 5 s (§15.18 part 12).
		$progress->update;
	} );

	my $fetchSeconds = Time::HiRes::time() - $started;

	# 6. A failed fetch: logged, and nothing else - no pref, no page, no marker
	# (§15.18 part 3). The fallback will sync a minute after the scan.
	if ( !$fetch->{ok} ) {
		$log->error( "scan-time collection sync failed: $fetch->{error} "
			. "(after $fetch->{requests} requests); the server will retry after the scan" );

		_final($progress);

		return 0;
	}

	# 7. The pass, the same one the server calls, ticking per album in its
	# decide walk and writing inside the scanner's transaction - it commits the
	# scan's pending work first, then writes, and leaves the commit to us
	# (Ownership::_write; §15.18 part 13).
	my $passStarted = Time::HiRes::time();
	my $applied     = Plugins::SqueezeWax::Ownership->apply( $fetch->{entries}, $progress );
	my $passSeconds = Time::HiRes::time() - $passStarted;

	if ( $applied ne 'ok' ) {
		$log->error("scan-time collection sync fetched the collection, but the ownership pass $applied");

		_final($progress);

		return 0;
	}

	# 8. The marker, after the pass and BEFORE the commit, so the two share one
	# fate. forceCommit swallows a failed commit (Slim/Schema.pm:2380-2384): if
	# this commit is lost, the marker is lost with the pass, and the fallback
	# re-syncs. Written any earlier, a lost commit would leave a marker claiming
	# a sync that never landed - and the fallback would believe it (§15.18 part
	# 8), which is the one failure here that would leave badges stale.
	#
	# A marker write that fails is the harmless direction: the pass commits
	# without it, and with no marker the fallback syncs again after the scan
	# and rewrites the same conclusions. So it is logged, not rolled back.
	my $marked = eval {
		Plugins::SqueezeWax::Schema->recordSync( $fetch->{items}, 'scan' );
		1;
	};

	if ( !$marked ) {
		$log->error( 'ownership was derived in the scan but the sync marker was not written ('
			. ( $@ || 'unknown error' ) . '); the server will sync again after the scan' );
	}

	# 9. The commit that makes the pass and the marker durable together.
	Slim::Schema->forceCommit;

	_final($progress);

	# One line that answers "did the scan badge my library". The pass's own
	# counters are its own summary line, logged just before this one.
	main::INFOLOG && $log->is_info && $log->info( sprintf(
		'scan-time collection sync: %d items in %d requests, fetch %.2fs, pass %.3fs; ownership derived',
		$fetch->{items}, $fetch->{requests}, $fetchSeconds, $passSeconds
	) );

	# runImporter returns this into the post pass, which discards it
	# (Slim/Music/Import.pm:452-459). 1 says "ownership was derived".
	return 1;
}

# Close the row with an EXPLICIT done. final() with no argument, or with 0,
# takes the total as done (Slim/Utils/Progress.pm:263, `shift || $self->total`),
# so a fetch that failed after page 1 set the total would show the row as
# complete. Passing what was actually done keeps a failed row looking failed.
# When nothing was done, done and total are both still 0 - the total is set
# only by the tick that answers page 1 - so the fallback to total is 0 too.
sub _final {
	my ($progress) = @_;

	return unless $progress;

	eval { $progress->final( $progress->done ); 1 }
		or $log->error( 'could not close the scan-time sync progress row: ' . ( $@ || 'unknown error' ) );

	return;
}

1;
