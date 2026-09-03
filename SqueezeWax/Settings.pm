package Plugins::SqueezeWax::Settings;

# Settings page: the Discogs tag-name list, and the detection action that finds
# out what the user's tagger actually wrote.
#
# Modelled on refs/lms-plugin-tidal/Settings.pm:20-51 - override handler, act on
# our own $params keys, delegate to SUPER::handler.

use strict;

use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Scheduler;
use Slim::Utils::Strings qw(string);

use Plugins::SqueezeWax::Library;
use Plugins::SqueezeWax::Match;
use Plugins::SqueezeWax::Schema;
use Plugins::SqueezeWax::Tags;

my $log   = logger('plugin.squeezewax');
my $prefs = preferences('plugin.squeezewax');

use constant SAMPLE_PER_FORMAT => 25;

# Detection state, server-process only. Not a pref: it is a transient report,
# and writing it to disk would outlive the library it describes.
my %detection;

sub name { Slim::Web::HTTP::CSRF->protectName('PLUGIN_SQUEEZEWAX_NAME') }

sub page { Slim::Web::HTTP::CSRF->protectURI('plugins/SqueezeWax/settings.html') }

# discogsTagNames is deliberately NOT in this list. Slim::Web::Settings's
# generic prefs() path only handles scalars; a list pref is edited with indexed
# form fields assembled by the plugin's own handler, which is how core edits
# mediadirs (Slim/Web/Settings/Server/Basic.pm:88-121).
sub prefs { return ($prefs) }

sub handler {
	my ( $class, $client, $params, $callback, @args ) = @_;

	# Called once on entry, never per tick. stillScanning is not a pure read:
	# Slim/Music/Import.pm:730-754 does external-scanner crash cleanup and can
	# fire a ['rescan','done'] notification as a side effect before it reads
	# metainformation.isScanning.
	my $scanning = Slim::Music::Import->stillScanning ? 1 : 0;

	if ( $params->{detectTagNames} ) {
		_startDetection($params, $scanning);
	}
	elsif ( $params->{saveSettings} ) {
		_saveTagNames($params, $scanning);
	}

	$params->{scanning} = $scanning;

	return $class->SUPER::handler( $client, $params, @args );
}

sub _saveTagNames {
	my ( $params, $scanning ) = @_;

	# Refused, not deferred. §3b's invalidation is DML on our attached schema,
	# and during a scan the scanner holds a write lock on every attached
	# database (finding 2b): BEGIN IMMEDIATE, forced by
	# sqlite_use_immediate_transaction at Slim/Utils/SQLiteHelper.pm:358, locks
	# all of them. Saving the pref and failing the invalidation is the exact
	# silent failure §3b exists to prevent.
	if ($scanning) {
		$params->{warning} = string('PLUGIN_SQUEEZEWAX_BUSY_SCANNING');
		return;
	}

	# Same reasoning one layer down: the detection worker only touches
	# library.db and the files, so it works with a broken squeezewax.db, but the
	# save does not. Writing the pref while the invalidation fails would leave
	# the strict cache stale with nothing to say so.
	if ( !Plugins::SqueezeWax::Schema->isReady ) {
		$params->{warning} = string('PLUGIN_SQUEEZEWAX_DB_UNUSABLE') . ' '
			. ( Plugins::SqueezeWax::Schema->lastError || '' );
		return;
	}

	# Indexed fields, assembled here - the mediadirs pattern
	# (Slim/Web/Settings/Server/Basic.pm:88-104).
	my @names;
	my %seen;

	for ( my $i = 0; defined $params->{"pref_discogsTagNames$i"}; $i++ ) {
		my $name = $params->{"pref_discogsTagNames$i"};

		next unless defined $name;

		$name =~ s/^\s+|\s+$//g;

		next if $name eq '';

		# A duplicate would be read twice and always agree with itself, so it
		# is noise rather than a conflict. Deduplicated case-insensitively, to
		# match _lookup's key comparison.
		next if $seen{ uc $name }++;

		push @names, $name;
	}

	my $old = $prefs->get('discogsTagNames') || [];

	$prefs->set( 'discogsTagNames', \@names );

	# §3b: invalidate only when the SET of names changed. A pure reorder, or a
	# change of case, changes nothing material - position only decides which tag
	# name is reported as the source of a clean hit, and no column stores that.
	# Making a reorder cost a full cold pass over every local file would be a
	# real cost for no benefit.
	#
	# Comparing inside the handler rather than hooking $prefs->setChange is
	# deliberate and has in-tree precedent: Slim/Web/Settings/Server/Basic.pm:118-121
	# compares old paths against new to decide whether to trigger a rescan.
	# setChange would fire on every save regardless, because
	# Slim::Utils::Prefs::Base::set dispatches onchange on `... || ref $new` and
	# ref $new is always true for an arrayref pref. See decisions §3b.
	if ( _setChanged( $old, \@names ) ) {
		my $rows = Plugins::SqueezeWax::Match->invalidateStrict;

		main::INFOLOG && $log->is_info && $log->info(
			'tag-name set changed; strict cache invalidated'
			. ( defined $rows ? " ($rows rows)" : ' (failed)' )
		);
	}
}

# Set comparison, case-insensitive. Order and case are not material.
sub _setChanged {
	my ( $old, $new ) = @_;

	my %oldSet = map { uc $_ => 1 } @$old;
	my %newSet = map { uc $_ => 1 } @$new;

	return 1 if scalar keys %oldSet != scalar keys %newSet;

	for my $name ( keys %newSet ) {
		return 1 unless $oldSet{$name};
	}

	return 0;
}

sub _startDetection {
	my ( $params, $scanning ) = @_;

	if ($scanning) {
		$params->{warning} = string('PLUGIN_SQUEEZEWAX_BUSY_SCANNING');
		return;
	}

	if ( $detection{running} ) {
		return;
	}

	# All the database work in one synchronous shot, materialised. Only the file
	# reads are spread over ticks - see Library::sample_albums for why holding a
	# statement handle across scheduler ticks would be unsafe.
	my $albums = Plugins::SqueezeWax::Library->sample_albums(SAMPLE_PER_FORMAT);

	%detection = (
		running  => 1,
		queue    => $albums,
		total    => scalar @$albums,
		done     => 0,
		keys     => {},   # tag key => { count, id, corroborated }
		formats  => {},   # content_type => albums sampled
		started  => time(),
	);

	# One album per tick, deliberately. A single readTags on a cold spinning
	# disk can exceed BLOCK_LIMIT (0.01s, Slim/Utils/Scheduler.pm:49) on its
	# own, so the limit cannot be honoured whatever we do - but batching would
	# turn a 0.5s hiccup into a multi-second freeze of the event loop. One at a
	# time keeps the worst case to one file.
	Slim::Utils::Scheduler::add_task( \&_detectionTick );
}

# Returns 1 while there is more to do, 0 when finished - the documented
# Slim::Utils::Scheduler contract (Slim/Utils/Scheduler.pm:53-67), the same
# shape Slim::Music::VirtualLibraries uses at :430.
sub _detectionTick {
	my $album = shift @{ $detection{queue} || [] };

	if ( !$album ) {
		$detection{running}  = 0;
		$detection{finished} = time();
		return 0;
	}

	$detection{done}++;
	$detection{formats}->{ $album->{content_type} || 'unknown' }++;

	my $url = $album->{candidates}->[0];

	if ($url) {
		my $tags = Plugins::SqueezeWax::Tags->readTrack($url);

		for my $hit ( Plugins::SqueezeWax::Tags->candidateKeys($tags) ) {
			my ( $key, $id, $corroborated ) = @$hit;

			my $entry = $detection{keys}->{$key} ||= {
				count        => 0,
				example      => $id,
				corroborated => $corroborated,
			};

			$entry->{count}++;

			# One corroborated sighting is enough to promote the key.
			$entry->{corroborated} ||= $corroborated;
		}
	}

	return 1;
}

sub beforeRender {
	my ( $class, $params ) = @_;

	$params->{prefs}->{pref_discogsTagNames} = Plugins::SqueezeWax::Tags->tagNames;

	$params->{dbReady} = Plugins::SqueezeWax::Schema->isReady ? 1 : 0;
	$params->{dbError} = Plugins::SqueezeWax::Schema->lastError;

	return unless %detection;

	$params->{detection} = {
		running => $detection{running},
		done    => $detection{done},
		total   => $detection{total},
	};

	# Corroborated keys first, then the demoted list. decisions §3 makes
	# detection the coverage report - "so silent failure is impossible" - so a
	# user whose tagger writes RELEASE_ID has to be shown something rather than
	# an empty result. The second list is explicitly labelled as unconfirmed.
	my @corroborated;
	my @other;

	for my $key ( sort keys %{ $detection{keys} } ) {
		my $entry = $detection{keys}->{$key};

		my $row = {
			name    => $key,
			count   => $entry->{count},
			example => $entry->{example},
		};

		if ( $entry->{corroborated} ) {
			push @corroborated, $row;
		}
		else {
			push @other, $row;
		}
	}

	$params->{detection}->{keys}  = \@corroborated;
	$params->{detection}->{other} = \@other;

	$params->{detection}->{formats} = [
		map { { name => $_, count => $detection{formats}->{$_} } }
			sort keys %{ $detection{formats} }
	];
}

1;
