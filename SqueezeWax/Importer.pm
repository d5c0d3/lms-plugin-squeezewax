package Plugins::SqueezeWax::Importer;

# Scanner-side entry point, named by <importmodule> in install.xml.
#
# The scanner never loads Plugin.pm: Slim::Utils::PluginManager::load skips any
# plugin without an <importmodule> and initialises only that class
# (Slim/Utils/PluginManager.pm:204). So anything the importer needs - log
# category, schema attach, prefs - has to be registered from here as well.

use strict;

use Slim::Music::Import;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Progress;

use Plugins::SqueezeWax::Library;
use Plugins::SqueezeWax::Match;
use Plugins::SqueezeWax::Schema;
use Plugins::SqueezeWax::Tags;

# WARN, matching Plugin.pm and both reference plugins
# (refs/lms-plugin-tidal/Plugin.pm:18-22). The step-2 reasoning for INFO - that
# our own lines were the only evidence of a healthy run - stopped holding once
# this importer had a row in the scan progress UI and LMS's own
# "Starting/Completed ... Scan" pair in scanner.log (Slim/Music/Import.pm:578,
# :710-712). Leaving INFO on while adding per-album work is how a plugin starts
# writing a line per album into everyone's log.
my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.squeezewax',
	description  => 'PLUGIN_SQUEEZEWAX_NAME',
	defaultLevel => 'WARN',
});

my $prefs = preferences('plugin.squeezewax');

# How often to commit. Our writes ride the scanner's long-lived transaction
# (scanner.pl:295 sets AutoCommit = 0 and never restores it), and the next
# guaranteed commit after our first write is endImporter
# (Slim/Music/Import.pm:716) at the very end of startScan - so on a large library
# that would be the whole run in one commit, and an abort halfway would lose all
# of it. Same order as Scanner::Local's per-chunk commits.
use constant COMMIT_EVERY => 200;

sub initPlugin {
	my $class = shift;

	main::INFOLOG && $log->is_info
		&& $log->info( 'Importer loaded (' . ( main::SCANNER ? 'scanner' : 'server' ) . ' process)' );

	Plugins::SqueezeWax::Schema->init();

	Slim::Music::Import->addImporter( $class, {
		# 'post', not 'file': all file importers finish before any post importer
		# starts (Slim/Music/Import.pm:382-384 against :454-456), which is what
		# guarantees albums exist before we try to match them. The reference
		# plugins are 'file' because they *create* tracks from a streaming
		# service (Slim/Plugin/OnlineLibraryBase.pm:33-40); we annotate what the
		# file pass produced.
		type   => 'post',

		# After everything else in the post pass - ReleaseTypes and
		# ExtendedBrowseModes at 90, VirtualLibraries and OnlineLibrary at 100,
		# VirtualLibrariesCleanup at 110 - all of which still touch albums.
		# optimizeDB runs after the loop, so 120 is still comfortably before it.
		weight => 120,

		# Not `use => 1`. runImporter's `$log->error("Starting $importer scan")`
		# and the progress row both sit inside the `use` guard
		# (Slim/Music/Import.pm:573-579), so gating here is what keeps an
		# unconfigured install silent rather than writing two lines and a dead
		# progress row on every scan forever. Same pattern as
		# Slim/Music/ReleaseTypes.pm:32, which gates on its own pref.
		#
		# Step 4 must relax this: Structural needs no tag names, so the gate
		# becomes "Strict configured OR Structural enabled".
		use    => scalar @{ $prefs->get('discogsTagNames') || [] },
	} );

	return 1;
}

sub startScan { if (main::SCANNER) {
	my $class = shift;

	if ( !Plugins::SqueezeWax::Schema->isReady ) {
		$log->warn( 'skipping Discogs matching: '
			. ( Plugins::SqueezeWax::Schema->lastError || 'squeezewax.db is not usable' ) );
		return 0;
	}

	my $names = Plugins::SqueezeWax::Tags->tagNames;

	# Belt and braces behind the `use` gate, for a pref cleared after
	# registration.
	if ( !@$names ) {
		main::INFOLOG && $log->is_info
			&& $log->info('no Discogs tag names configured; nothing to match');
		return 0;
	}

	# Checked once, here, rather than relying on the per-write guard inside
	# Match. If we cannot write at all there is no point reading 5,000 files.
	if ( !Plugins::SqueezeWax::Match->_writeOk ) {
		return 0;
	}

	my $total = Plugins::SqueezeWax::Library->albumCount;

	my $progress = Slim::Utils::Progress->new({
		type  => 'importer',
		name  => 'plugin_squeezewax_match',
		total => $total,
		# Deliberately no `every`: the progress-table write and the scanner's
		# HTTP POST to the server are both inside one 5-second throttle
		# (Slim/Utils/Progress.pm:221-245), and `every` would make both fire per
		# album - thousands of synchronous round trips. The throttle is also what
		# bounds abort latency to ~5s, which is intended.
	});

	my %count = ( examined => 0, confirmed => 0, candidate => 0, none => 0, skipped => 0 );
	my $since = 0;

	main::INFOLOG && $log->is_info
		&& $log->info("Discogs matching: $total albums, tags [@$names]");

	Plugins::SqueezeWax::Library->eachAlbum( sub {
		my $album = shift;

		# update() per album is also the entire abort mechanism: it reaches
		# Slim::Utils::SQLiteHelper::updateProgress, which exits the scanner
		# outright when the server answers "abort" (:443-460). There is nothing
		# to check and nothing to return - Slim::Music::Import->hasAborted is
		# server-side state and is never set in this process.
		$progress->update( Plugins::SqueezeWax::Library->albumLabel($album) );

		# Nothing to read tags from. Streaming albums are real tracks rows with
		# audio = 1, and their timestamp is structurally NULL, so they could
		# never skip on a later scan either - see Library's iterator.
		if ( !$album->{local_tracks} ) {
			$count{skipped}++;
			return 1;
		}

		my $state = Plugins::SqueezeWax::Match->strictState( $album->{album_key} );

		if ( _canSkip( $album, $state ) ) {
			$count{skipped}++;
			return 1;
		}

		$count{examined}++;

		my $decision = _examine( $album, $names );
		my $outcome  = Plugins::SqueezeWax::Match->recordStrict( $album, $decision, $state );

		$count{confirmed}++ if ( $outcome || '' ) eq 'confirmed';
		$count{candidate}++ if ( $outcome || '' ) eq 'candidate';
		$count{none}++      if ( $outcome || '' ) eq 'none';

		if ( ++$since >= COMMIT_EVERY ) {
			Slim::Schema->forceCommit;
			$since = 0;
		}

		return 1;
	} );

	$progress->final;

	my $summary = "Discogs matching finished: examined $count{examined}, "
		. "confirmed $count{confirmed}, conflicts $count{candidate}, "
		. "no tag $count{none}, skipped $count{skipped}";

	# Escalated to warn in the one case LMS's own start/complete pair cannot
	# report: a mistyped tag name produces "examined 4,800, confirmed 0" and
	# nothing else, and at WARN our INFO summary would be invisible. examined > 0
	# is part of the condition deliberately - a library where everything is
	# already matched examines nothing and must stay quiet.
	if ( $count{confirmed} == 0 && $count{examined} > 0 ) {
		$log->warn("$summary - check the configured tag names");
	}
	else {
		main::INFOLOG && $log->is_info && $log->info($summary);
	}

	Slim::Music::Import->endImporter($class);

	# runImporter assigns the return and runScan sums it into $changes
	# (Slim/Music/Import.pm:405-406, :580). The post pass discards it, so this is
	# convention rather than correctness - but returning undef into a += is the
	# kind of thing the XXX comment at :403 exists because of.
	return $count{confirmed};
} }

# Skip when what we already recorded still describes the files on disk.
#
# A NULL source_timestamp on either side never compares equal, which is what
# makes §3b's invalidation work and what stops an album whose timestamp cannot be
# established from skipping forever.
sub _canSkip {
	my ( $album, $state ) = @_;

	return 0 unless $state;
	return 0 unless defined $state->{source_timestamp};
	return 0 unless defined $album->{source_timestamp};

	return $state->{source_timestamp} == $album->{source_timestamp};
}

# Read the primary local track, and fall back to one more - never all. A
# compilation assembled from per-track tagging is not a maintained collection and
# is not worth paying 12x the file reads to accommodate (decisions §3).
sub _examine {
	my ( $album, $names ) = @_;

	my $decision = {};

	for my $url ( @{ $album->{candidates} } ) {
		my $tags = Plugins::SqueezeWax::Tags->readTrack($url);

		$decision = Plugins::SqueezeWax::Tags->decide($tags);

		# Anything but "no configured tag present" is an answer.
		last if $decision->{id} || $decision->{conflict};
	}

	return $decision;
}

1;
