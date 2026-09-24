package Plugins::SqueezeWax::Settings;

# Settings page: the Discogs tag-name list, and the detection action that finds
# out what the user's tagger actually wrote.
#
# Modelled on refs/lms-plugin-tidal/Settings.pm:20-51 - override handler, act on
# our own $params keys, delegate to SUPER::handler.

use strict;

use base qw(Slim::Web::Settings);

use Slim::Utils::DateTime;
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

# A run that has not finished in this long is treated as dead, so a wedged
# detection cannot outlive the session with no way for the user to retry.
use constant DETECTION_TIMEOUT => 600;

# Detection state, server-process only. Not a pref: it is a transient report,
# and writing it to disk would outlive the library it describes.
my %detection;

# The queue page is constructed from here, not from Plugin.pm, so that the two
# pages are registered together and by the one file that already knows about the
# web UI. Slim/Plugin/OnlineLibrary/Settings.pm:23 constructs its
# EditGenreMappings the same way, and Spotty's Settings.pm:24 its Auth page.
#
# SUPER::new is still called, so THIS page keeps its settings-menu entry; the
# queue's own `new` deliberately does not, so it appears only through the link
# on this page (decisions §15.16 part 1).
sub new {
	my $class = shift;

	require Plugins::SqueezeWax::Queue;
	Plugins::SqueezeWax::Queue->new();

	return $class->SUPER::new(@_);
}

sub name { Slim::Web::HTTP::CSRF->protectName('PLUGIN_SQUEEZEWAX_NAME') }

sub page { Slim::Web::HTTP::CSRF->protectURI('plugins/SqueezeWax/settings.html') }

# discogsTagNames is deliberately NOT in this list. Slim::Web::Settings's
# generic prefs() path only handles scalars; a list pref is edited with indexed
# form fields assembled by the plugin's own handler, which is how core edits
# mediadirs (Slim/Web/Settings/Server/Basic.pm:88-121).
#
# discogsToken IS a scalar, so unlike discogsTagNames it goes through this
# generic path (Slim/Web/Settings.pm:135-176): the base handler saves
# pref_discogsToken on saveSettings and populates params.prefs.pref_discogsToken
# for the template, same as core's own password field (HTML/EN/settings/
# server/security.html).
#
# discogsSyncInterval was here until §15.15 part 1 removed the scheduled sync.
# Nothing replaces it: there is no setting for a thing that no longer happens.
sub prefs { return ($prefs, qw(discogsToken)) }

sub handler {
	my ( $class, $client, $params, $callback, @args ) = @_;

	# Called once on entry, never per tick. stillScanning is not a pure read:
	# Slim/Music/Import.pm:730-754 does external-scanner crash cleanup and can
	# fire a ['rescan','done'] notification as a side effect before it reads
	# metainformation.isScanning.
	my $scanning = Slim::Music::Import->stillScanning ? 1 : 0;

	# ORDER MATTERS, and not for a stylistic reason. settings/footer.html:39
	# puts a HIDDEN saveSettings=1 in the form, beside the visible Save button
	# at :38, so EVERY submit from this page carries saveSettings whichever
	# button was clicked. Tested before the named action buttons it swallows
	# them: the page re-renders having saved, the action never runs, and
	# nothing is logged, because the action's own code was never reached.
	#
	# So every named action is tested first and saveSettings is the fallback -
	# "no action button was clicked, so this is a plain Save". detectTagNames
	# was already ahead of it and worked; syncNow and testToken were behind it
	# and did not (found on the reference server 2026-09-22, both buttons dead
	# in 0.0.0.3).
	if ( $params->{detectTagNames} ) {
		_startDetection($params, $scanning);
	}
	elsif ( $params->{syncNow} ) {
		# Same deferral as _testToken below, for the same reason.
		return _syncNow( $class, $client, $params, $callback, \@args, $scanning );
	}
	elsif ( $params->{testToken} ) {
		# Async and self-contained: renders the page itself via $callback
		# once Discogs answers, the same deferral shape
		# Slim::Plugin::JiveExtras::Settings uses around a settings-page
		# SimpleAsyncHTTP call (refs/slimserver/Slim/Plugin/JiveExtras/
		# Settings.pm:83-101,134). Must return here rather than fall through
		# to the synchronous SUPER::handler call below.
		return _testToken( $class, $client, $params, $callback, \@args, $scanning );
	}
	elsif ( $params->{saveSettings} ) {
		_saveTagNames($params, $scanning);
	}

	$params->{scanning} = $scanning;

	# $callback is core's fourth argument ($pageSetup). It reaches only the
	# player-redirect branch and the async form at
	# Slim/Web/Settings/Server/Plugins.pm:49, neither of which applies to us -
	# but refs/lms-plugin-tidal/Settings.pm passes it through and dropping an
	# argument core defines is the kind of thing that breaks on an upgrade.
	return $class->SUPER::handler( $client, $params, $callback, @args );
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

# The manual "Sync collection now" button - one of §13.7's three triggers, and
# the only one that has a user watching it. The other two are timers in
# Plugin.pm, which is where they have to be: they must work on a headless
# server, and this file is loaded only under main::WEBUI.
#
# Everything that decides anything lives in API/Async.pm - including the guard
# that stops this button, the interval timer and ['rescan','done'] from starting
# three overlapping syncs. This sub renders a result; it does not own one.
sub _syncNow {
	my ( $class, $client, $params, $callback, $args, $scanning ) = @_;

	# Refused during a scan, not queued. The sync itself would survive one - it
	# touches no database at all - but the settings page's own conventions
	# refuse every action while scanning, and a button that appears to work and
	# then reports nothing is worse than one that says why it did not.
	if ($scanning) {
		$params->{warning} = string('PLUGIN_SQUEEZEWAX_BUSY_SCANNING');
		return _finishSyncNow( $class, $client, $params, $callback, $args, $scanning );
	}

	# The token in the FIELD, exactly as _testToken does (§15.15 part 3).
	#
	# This read the stored pref until 2026-09-22, while the shared form saved
	# the field afterwards in _finishSyncNow - so pasting a token and pressing
	# this button synced with the OLD token and stored the new one, and the
	# page gave no hint that it had. Observed on the reference server while
	# testing a deliberately wrong token: the first press succeeded against the
	# previous token. Both buttons now mean the same thing by "the token", and
	# the page says so.
	my $token = $params->{pref_discogsToken};
	$token = $prefs->get('discogsToken') unless defined $token && length $token;

	if ( !defined $token || $token eq '' ) {
		$params->{syncResult} = string('PLUGIN_SQUEEZEWAX_SYNC_NO_TOKEN');
		return _finishSyncNow( $class, $client, $params, $callback, $args, $scanning );
	}

	require Plugins::SqueezeWax::API::Async;

	# Saved BEFORE the sync, not after, and the order is the whole point.
	#
	# The shared form saves every scalar pref in _finishSyncNow, via
	# SUPER::handler - which runs from the SYNC'S OWN CALLBACK, so it lands
	# after the sync has finished. Plugin.pm's setChange on discogsToken clears
	# the rejection pause, because a new token deserves a new chance (§15.15
	# parts 2 and 3). Put together, a sync that was rejected set the pause and
	# the save that followed it immediately wiped it: observed on the reference
	# server 2026-09-24, where a wrong token was rejected at 14:37:02 and the
	# next finished scan synced anyway rather than being skipped.
	#
	# Writing it here makes the order what it reads as: the token changes, the
	# pause clears, the sync runs, and a rejection sticks. SUPER::handler's
	# later write is then a no-op - Slim/Utils/Prefs/Base.pm:94-97 suppresses a
	# scalar set that does not change the value, onchange included - so the
	# hook cannot fire twice either.
	$prefs->set( 'discogsToken', $token );

	Plugins::SqueezeWax::API::Async->sync( $token, sub {
		my ($result) = @_;

		$params->{syncResult} = _syncResultString($result);

		_finishSyncNow( $class, $client, $params, $callback, $args, $scanning );
	} );

	return;
}

# §14.2: a rejected token must read differently from a dropped connection, and
# both must be distinguishable from "it worked". The error vocabulary is
# API.pm's classifyResponse plus API/Async.pm's own three.
sub _syncResultString {
	my ($result) = @_;

	if ( $result->{ok} ) {
		$log->info( "collection sync: $result->{items} items in $result->{requests} requests" )
			if main::INFOLOG && $log->is_info;

		return sprintf( string('PLUGIN_SQUEEZEWAX_SYNC_OK'),
			$result->{items} // 0, $result->{requests} // 0 );
	}

	my $error = $result->{error} || 'unknown';

	# error, not warn, and separately from the rest: this one is not going to
	# fix itself, and every future interval tick will fail the same way until
	# the user does something about it.
	if ( $error eq 'unauthorized' ) {
		$log->error('collection sync failed: Discogs rejected the token');

		return string('PLUGIN_SQUEEZEWAX_SYNC_FAIL_UNAUTHORIZED');
	}

	if ( $error eq 'already_running' ) {
		return string('PLUGIN_SQUEEZEWAX_SYNC_ALREADY_RUNNING');
	}

	# The three ways step 7 can stop a sync short of writing ownership. Each
	# reads differently because each calls for something different from the
	# user: wait, nothing, or look at the log.
	if ( $error eq 'refused' ) {
		main::INFOLOG && $log->is_info
			&& $log->info('ownership pass declined - a scan is running');

		return string('PLUGIN_SQUEEZEWAX_SYNC_REFUSED');
	}

	if ( $error eq 'count_mismatch' || $error eq 'count_unknown' ) {
		$log->warn("collection sync could not be shown complete: $error");

		return string( $error eq 'count_mismatch'
			? 'PLUGIN_SQUEEZEWAX_SYNC_COUNT_MISMATCH'
			: 'PLUGIN_SQUEEZEWAX_SYNC_COUNT_UNKNOWN' );
	}

	$log->warn("collection sync failed: $error");

	return sprintf( string('PLUGIN_SQUEEZEWAX_SYNC_FAIL'), $error );
}

sub _finishSyncNow {
	my ( $class, $client, $params, $callback, $args, $scanning ) = @_;

	$params->{scanning} = $scanning;

	$callback->( $client, $params, $class->SUPER::handler( $client, $params ), @$args );
}

# GET /oauth/identity (decisions §9.7's "Token sanity check"). Server-side, so
# SimpleAsyncHTTP per CLAUDE.md. Request construction and response
# classification are API.pm's job - it owns no transport of its own - and only
# the wiring differs between here and API/Async.pm, which does the same thing
# for the collection sync with retry and rate-limit accounting on top.
sub _testToken {
	my ( $class, $client, $params, $callback, $args, $scanning ) = @_;

	if ($scanning) {
		$params->{warning} = string('PLUGIN_SQUEEZEWAX_BUSY_SCANNING');
		return _finishTestToken( $class, $client, $params, $callback, $args, $scanning );
	}

	if ( !Plugins::SqueezeWax::Schema->isReady ) {
		$params->{warning} = string('PLUGIN_SQUEEZEWAX_DB_UNUSABLE') . ' '
			. ( Plugins::SqueezeWax::Schema->lastError || '' );
		return _finishTestToken( $class, $client, $params, $callback, $args, $scanning );
	}

	# Test what's currently in the field, even if unsaved - the point of a
	# "Test token" button is to check before committing to Save.
	my $token = $params->{pref_discogsToken};
	$token = $prefs->get('discogsToken') unless defined $token && length $token;

	if ( !defined $token || $token eq '' ) {
		$params->{tokenTestResult} = string('PLUGIN_SQUEEZEWAX_TOKEN_TEST_MISSING');
		return _finishTestToken( $class, $client, $params, $callback, $args, $scanning );
	}

	require Plugins::SqueezeWax::API;
	require Slim::Networking::SimpleAsyncHTTP;

	my ( $url, @headers ) = Plugins::SqueezeWax::API->buildRequest( '/oauth/identity', {}, $token );

	# Same shape, and the same correction, as API/Async.pm's _handle: every
	# status that is not 2xx or 3xx reaches the ERROR callback
	# (Slim/Networking/Async/HTTP.pm:434-436), and onError sets neither code nor
	# content on $http - it passes the HTTP::Response as its third argument
	# instead (SimpleAsyncHTTP.pm:96). Reading only $http->code made a 401
	# indistinguishable from a dropped connection, which is precisely what this
	# button exists to tell apart.
	my $done = sub {
		my ( $http, undef, $response ) = @_;

		my $code    = $http->code;
		my $content = $http->content;

		if ( !defined $code && $response ) {
			$code    = $response->code;
			$content = $response->content;
		}

		my $result = Plugins::SqueezeWax::API->classifyResponse( $code, $content );

		_tokenTested( $class, $client, $params, $callback, $args, $scanning, $result );
	};

	Slim::Networking::SimpleAsyncHTTP->new( $done, $done, { timeout => 15 } )->get( $url, @headers );

	return;
}

sub _tokenTested {
	my ( $class, $client, $params, $callback, $args, $scanning, $result ) = @_;

	if ( $result->{ok} ) {
		my $username = $result->{data} && $result->{data}->{username};

		$params->{tokenTestResult} = $username
			? sprintf( string('PLUGIN_SQUEEZEWAX_TOKEN_TEST_OK'), $username )
			: string('PLUGIN_SQUEEZEWAX_TOKEN_TEST_OK_NOUSER');
	}
	else {
		$params->{tokenTestResult} = _tokenTestFailureString($result);
	}

	_finishTestToken( $class, $client, $params, $callback, $args, $scanning );
}

sub _tokenTestFailureString {
	my ($result) = @_;

	my %tokens = (
		unauthorized   => 'PLUGIN_SQUEEZEWAX_TOKEN_TEST_FAIL_UNAUTHORIZED',
		not_found      => 'PLUGIN_SQUEEZEWAX_TOKEN_TEST_FAIL_NOT_FOUND',
		rate_limited   => 'PLUGIN_SQUEEZEWAX_TOKEN_TEST_FAIL_RATE_LIMITED',
		server_error   => 'PLUGIN_SQUEEZEWAX_TOKEN_TEST_FAIL_SERVER_ERROR',
		no_response    => 'PLUGIN_SQUEEZEWAX_TOKEN_TEST_FAIL_NO_RESPONSE',
		empty_body     => 'PLUGIN_SQUEEZEWAX_TOKEN_TEST_FAIL_EMPTY_BODY',
		malformed_json => 'PLUGIN_SQUEEZEWAX_TOKEN_TEST_FAIL_MALFORMED_JSON',
	);

	my $token = $tokens{ $result->{error} || '' };

	return string($token) if $token;

	return sprintf( string('PLUGIN_SQUEEZEWAX_TOKEN_TEST_FAIL_UNKNOWN'), $result->{code} // '?' );
}

sub _finishTestToken {
	my ( $class, $client, $params, $callback, $args, $scanning ) = @_;

	$params->{scanning} = $scanning;

	$callback->( $client, $params, $class->SUPER::handler( $client, $params ), @$args );
}

sub _startDetection {
	my ( $params, $scanning ) = @_;

	if ($scanning) {
		$params->{warning} = string('PLUGIN_SQUEEZEWAX_BUSY_SCANNING');
		return;
	}

	# Staleness backstop. Scheduler splices a dead task out of its list, so
	# running => 1 with nothing behind it is unrecoverable without this - and a
	# wedged run must not outlive the session. Each album is also individually
	# evalled, so reaching this is a belt-and-braces case rather than the
	# expected one.
	if ( $detection{running} && ( time() - ( $detection{started} || 0 ) ) < DETECTION_TIMEOUT ) {
		return;
	}

	if ( $detection{running} ) {
		$log->warn('previous detection run appears to have died; starting a new one');
		Slim::Utils::Scheduler::remove_task( \&_detectionTick );
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
		keys       => {},  # tag key => { count, example, corroborated, formats }
		formats    => {},  # content_type => albums sampled
		unreadable => 0,
		started    => time(),
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

	my $format = $album->{content_type} || 'unknown';

	$detection{done}++;
	$detection{formats}->{$format}++;

	# Each album's own eval. Slim::Utils::Scheduler evals the task and splices it
	# out of the list on death (Slim/Utils/Scheduler.pm:156-172), so the event
	# loop is safe - but %detection would be left with running => 1 and no task
	# behind it, _startDetection would return early forever, and the page would
	# show "running (17/50)" until the server restarted. The loop survives; the
	# feature does not. readTrack already evals readTags, so the residual risk is
	# small and the consequence is total, which is the wrong ratio to leave.
	my $ok = eval {
		my $url = $album->{candidates}->[0];

		if ($url) {
			my $tags = Plugins::SqueezeWax::Tags->readTrack($url);

			for my $hit ( Plugins::SqueezeWax::Tags->candidateKeys($tags) ) {
				my ( $key, $id, $corroborated, $raw ) = @$hit;

				my $entry = $detection{keys}->{$key} ||= {
					count        => 0,
					example      => $raw,
					corroborated => $corroborated,
					formats      => {},
				};

				$entry->{count}++;

				# Per format, not just a global count. The sample is stratified
				# by content type precisely because the same tag is spelled
				# differently per format - MUSICBRAINZ_ALBUMID from FLAC
				# (Slim/Formats/FLAC.pm:51) against 'MUSICBRAINZ ALBUM ID' from
				# MP3 (Slim/Formats/MP3.pm:48). Recording only a global count
				# throws away the finding the stratified sample was taken for:
				# the user would see two similar keys with no reason to tick
				# both, which is the mistake the list-of-names design exists to
				# prevent.
				$entry->{formats}->{$format}++;

				# One corroborated sighting is enough to promote the key.
				$entry->{corroborated} ||= $corroborated;
			}
		}

		1;
	};

	if ( !$ok ) {
		# Counted and surfaced, not swallowed: "sampled 50, 12 unreadable" is
		# coverage information, and without it an unreadable album looks exactly
		# like one that simply has no tags.
		$detection{unreadable}++;
		$log->warn( "detection could not read album $album->{album_id}: $@" );
	}

	return 1;
}

sub beforeRender {
	my ( $class, $params ) = @_;

	$params->{prefs}->{pref_discogsTagNames} = Plugins::SqueezeWax::Tags->tagNames;

	$params->{dbReady} = Plugins::SqueezeWax::Schema->isReady ? 1 : 0;
	$params->{dbError} = Plugins::SqueezeWax::Schema->lastError;

	# The count beside the queue link. One COUNT(*) on a small table, not the
	# queue's own render - the page walks the library to build its lists, and
	# doing that here would make every settings page load pay for a page the
	# user may not open. The predicate is the queue's own, D3's second clause
	# included, so the number and the list cannot disagree.
	if ( $params->{dbReady} ) {
		my ($open) = Slim::Schema->dbh->selectrow_array(
			q{SELECT COUNT(*) FROM squeezewax.discogs_match
			   WHERE review_reason IS NOT NULL
			      OR ( match_tier = 'strict' AND discogs_release_id IS NULL )}
		);

		$params->{queueOpenItems} = $open || 0;
	}

	# Required lazily, as _syncNow does: this is the only other reader, and
	# Async.pm pulls in SimpleAsyncHTTP and Timers for a page that may never
	# trigger a sync at all.
	require Plugins::SqueezeWax::API::Async;
	$params->{sync} = Plugins::SqueezeWax::API::Async->status;

	# Formatted here, not in the template: Slim::Utils::DateTime honours the
	# server's own shortdateFormat/timeFormat prefs (Slim/Utils/DateTime.pm:81,
	# :103), so the timestamp reads the way every other date in the web UI does
	# rather than in whatever this plugin would have invented.
	if ( $params->{sync}->{lastSynced} ) {
		$params->{sync}->{lastSyncedF} =
			Slim::Utils::DateTime::shortDateF( $params->{sync}->{lastSynced} ) . ' '
			. Slim::Utils::DateTime::timeF( $params->{sync}->{lastSynced} );
	}

	return unless %detection;

	$params->{detection} = {
		running    => $detection{running},
		done       => $detection{done},
		total      => $detection{total},
		unreadable => $detection{unreadable},
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

			# "FLAC 25, MP3 4" rather than a bare 29. This is the whole point of
			# stratifying the sample.
			formats => join( ', ',
				map { "$_ $entry->{formats}->{$_}" }
					sort keys %{ $entry->{formats} || {} } ),
		};

		if ( $entry->{corroborated} ) {
			push @corroborated, $row;
		}
		else {
			push @other, $row;
		}
	}

	# Not 'keys': Template Toolkit has a `keys` hash vmethod, and TT only
	# resolves the hash entry first *because it exists*. If it were ever absent,
	# detection.keys would silently become ('running','done',...), .size would be
	# truthy, and the FOREACH would render blank rows rather than nothing.
	$params->{detection}->{found} = \@corroborated;
	$params->{detection}->{other} = \@other;

	$params->{detection}->{formats} = [
		map { { name => $_, count => $detection{formats}->{$_} } }
			sort keys %{ $detection{formats} }
	];
}

1;
