package Plugins::SqueezeWax::Queue;

# The review queue: one web page, one list, one action, and the action writes
# nothing. Since §15.46 (GitHub #8) the queue lists, never decides: each album
# says why it is there and what to change outside SqueezeWax - the Discogs tag
# in the files, or the Discogs collection - and then a rescan or a sync does the
# rest. "Show tags" reads two files and writes nothing (§15.17 part 1). The
# re-match list, reject, the orphan list and relink are gone; a request still
# carrying one of their action names renders the page and does nothing else.
#
# Its own page rather than a section of the settings page, and the reason is not
# taste. The settings form carries a hidden saveSettings on every submit
# (settings/footer.html:39), so every button on that page also saves - which
# broke action dispatch there twice, in 0.0.0.3 and again in 0.0.0.5. A page
# with no prefs() has nothing to save, so the same accident cannot happen here
# (decisions §15.16 part 1).
#
# The shape is core's own. Slim/Web/Settings/Server/Status.pm is a
# Slim::Web::Settings subclass with no prefs() override - it inherits the empty
# one at Slim/Web/Settings.pm:117-119 - which dispatches on its own action name
# ('abortScan', :26), never tests saveSettings, and whose template sets
# nosubmit = 1 (HTML/EN/settings/server/status.html:44) so the footer emits no
# visible Save button. That is this page, feature for feature.
#
# `new` registers the page and nothing else, so the queue does not appear in the
# settings menu's drop-down: it is reached from the plugin's own settings page,
# with the count of open items. Slim/Plugin/OnlineLibrary/EditGenreMappings.pm
# :19-22 is the precedent, constructed from its Settings.pm:23 exactly as this
# is constructed from ours, and Spotty's Settings/Auth.pm:26-32 does the same.
#
# Web UI only, like Settings.pm: Plugin.pm requires both under main::WEBUI.

use strict;

use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);

use Plugins::SqueezeWax::Library;
use Plugins::SqueezeWax::Schema;
use Plugins::SqueezeWax::Tags;

my $log = logger('plugin.squeezewax');

# Reason to string token. A reason the user cannot read is not a review queue,
# it is a table of internal vocabulary.
# Which sentence a conflict's DETAIL gets, once the user has asked to see the
# tags. The stored review_reason is 'conflict' whichever of the three it is - one
# reason value, because the column records "these tags are contested" and the
# remedy is the same either way (§15.22) - so the kind is recomputed from the
# files at render time, along with the file names it needs.
#
# Before step 8c there was one sentence, PLUGIN_SQUEEZEWAX_REASON_CONFLICT's "Two
# tags name different releases", and it was true only of the in-file case. Saying
# it of an album where one file is tagged and another is not tells the user
# something untrue about their own library, which §15.17 part 3 ranks below a
# missing feature. So that string became the generic one - true of every conflict,
# which is what the reason COLUMN can honestly claim - and these three carry the
# specifics.
my %CONFLICT_KIND_STRING = (
	'in-file'       => 'PLUGIN_SQUEEZEWAX_QUEUE_TAGS_IN_FILE',
	'cross-ids'     => 'PLUGIN_SQUEEZEWAX_QUEUE_TAGS_CROSS_IDS',
	'cross-partial' => 'PLUGIN_SQUEEZEWAX_QUEUE_TAGS_CROSS_PARTIAL',
);

my %REASON_STRING = (
	conflict          => 'PLUGIN_SQUEEZEWAX_REASON_CONFLICT',
	ambiguous         => 'PLUGIN_SQUEEZEWAX_REASON_AMBIGUOUS',
	'artist-disagree' => 'PLUGIN_SQUEEZEWAX_REASON_ARTIST_DISAGREE',
	'artist-absent'   => 'PLUGIN_SQUEEZEWAX_REASON_ARTIST_ABSENT',
	'various-gated'   => 'PLUGIN_SQUEEZEWAX_REASON_VARIOUS_GATED',
);

# Reason to "what to do" (§15.46 part 7). Every fix is a tag edit or a collection
# edit, then a rescan or a sync: nothing on this page writes, so nothing on it can
# be the fix. An album with no local tracks cannot be tagged at all (§15.46 part
# 3), so it gets PLUGIN_SQUEEZEWAX_QUEUE_STREAMING_NOTE instead of a line telling
# the user to edit files that do not exist.
my %FIX_STRING = (
	conflict          => 'PLUGIN_SQUEEZEWAX_FIX_CONFLICT',
	ambiguous         => 'PLUGIN_SQUEEZEWAX_FIX_AMBIGUOUS',
	'artist-disagree' => 'PLUGIN_SQUEEZEWAX_FIX_ARTIST_DISAGREE',
	'artist-absent'   => 'PLUGIN_SQUEEZEWAX_FIX_ARTIST_ABSENT',
	'various-gated'   => 'PLUGIN_SQUEEZEWAX_FIX_VARIOUS_GATED',
);

sub page { Slim::Web::HTTP::CSRF->protectURI('plugins/SqueezeWax/queue.html') }

# No `name`, and no SUPER::new. Together those keep the page out of the settings
# drop-down while still registering the handler: Slim/Web/Settings.pm:51-54
# registers the page from `new`, and :56-63 adds the menu link only for a class
# with both `page` and a non-empty `name`.
sub new {
	my $class = shift;

	Slim::Web::Pages->addPageFunction( $class->page, $class );
}

# No prefs(). The base returns the empty list (Slim/Web/Settings.pm:117-119),
# the base handler's save loop therefore runs zero times (:150-182), and the
# footer's hidden saveSettings reaches a handler that saves nothing. That is the
# whole of why this page cannot repeat the settings page's dispatch bug.

sub handler {
	my ( $class, $client, $params, $callback, @args ) = @_;

	# Once on entry, never per action. stillScanning is not a pure read:
	# Slim/Music/Import.pm:730-754 does external-scanner crash cleanup and can
	# fire a ['rescan','done'] notification as a side effect.
	my $scanning = Slim::Music::Import->stillScanning ? 1 : 0;

	# One action name, tested explicitly, and saveSettings NOT among them. On the
	# settings page saveSettings has to be the last-tested fallback because the
	# shared form sends it with every submit; here it is simply ignored, which is
	# the stronger position and the one Status.pm takes.
	#
	# rematch, link, reject and relink were removed with manual matching
	# (§15.46). A request still carrying one - an old page left open across the
	# update - falls through to the render: no write, no Discogs request.
	if ( $params->{showtags} ) {
		_showTags( $params, $scanning );
	}

	$params->{scanning} = $scanning;

	return $class->SUPER::handler( $client, $params, $callback, @args );
}

# ---------------------------------------------------------------------------
# The action.
#
# A plain function taking its arguments directly (CLAUDE.md's calling
# convention), refusing during a scan with the same string the settings page
# uses. Refused rather than queued: someone is looking at the page waiting for an
# answer, and a button that appears to work and then reports nothing is worse
# than one that says why it did not.
# ---------------------------------------------------------------------------

sub _refused {
	my ( $params, $scanning ) = @_;

	if ($scanning) {
		$params->{warning} = string('PLUGIN_SQUEEZEWAX_BUSY_SCANNING');
		return 1;
	}

	if ( !Plugins::SqueezeWax::Schema->isReady ) {
		$params->{warning} = string('PLUGIN_SQUEEZEWAX_DB_UNUSABLE') . ' '
			. ( Plugins::SqueezeWax::Schema->lastError || '' );
		return 1;
	}

	return 0;
}

# Bytes to characters, for DISPLAY ONLY (§15.17 part 6).
#
# Everything this page shows comes out of the database or the iterator as raw
# bytes: contributors.name is a blob, nothing under Slim/ sets sqlite_unicode,
# and the snapshots deliberately store bytes so orphan recovery compares like
# with like (§15.12, D5). Handed to the template unchanged, UTF-8 bytes are
# rendered as Latin-1 and "Gling-Gló / Björk" reaches the user as
# "Gling-GlÃ³ / BjÃ¶rk" - seen on the 2026-09-26 screenshot.
#
# Nothing written to the database changes.
#
# A string that will not decode is shown AS STORED rather than dropped: a
# mangled title is still enough to recognise an album by, and a missing row is
# not. _decode returns undef on failure, which is the signal to fall back.
sub _display {
	my ($bytes) = @_;

	return undef unless defined $bytes;

	my $decoded = Plugins::SqueezeWax::Ownership::_decode($bytes);

	return defined $decoded ? $decoded : $bytes;
}

# An album_key off a form is 32 hex characters or it is nothing. Checked before
# it reaches a query, so a malformed one is a refusal rather than a row that
# happens not to match.
sub _albumKey {
	my ($value) = @_;

	return undef unless defined $value && $value =~ /^[0-9a-f]{32}$/;

	return $value;
}

# The album key for an action, from either of the two places it can arrive.
#
# With JavaScript, the page adds a hidden album_key and sets the action name to
# '1'. Without it, the browser submits the button's own name and value - and the
# value IS the album key, which is why the markup puts it there. So the fallback
# is not a guess: it is the same string by the shorter route, and it is what
# makes showtags work on a page with scripting off.
sub _actionKey {
	my ( $params, $action ) = @_;

	return _albumKey( $params->{album_key} ) || _albumKey( $params->{$action} );
}

# Show the tags of ONE conflict row, because the user asked.
#
# Writes nothing, and issues no Discogs request. It only records which album
# the render should expand; _reviewList does the reading, for that album alone.
#
# Refused while scanning (§15.17 part 1). It touches no database and would be
# harmless mid-scan, but reading files during a scan competes with the scanner
# for the same disk, and the page said so uniformly when it had four actions;
# the rule is kept rather than re-argued.
sub _showTags {
	my ( $params, $scanning ) = @_;

	return if _refused( $params, $scanning );

	my $key = _actionKey( $params, 'showtags' );

	if ( !$key ) {
		$params->{warning} = string('PLUGIN_SQUEEZEWAX_QUEUE_NOT_FOUND');
		return;
	}

	$params->{showTagsFor} = $key;
}

# ---------------------------------------------------------------------------
# The list.
# ---------------------------------------------------------------------------

# Every row that is in the queue, by either route.
#
# The second clause is D3: a conflict written before migration 4 carries no
# mark, and §3a's own predicate - strict with a NULL release id - is exactly
# what a fresh one looks like. Not a backfill, and exact rather than
# approximate. An INCUMBENT conflict written before migration 4 cannot be found
# at all: nothing recorded it and scanner.log is rewritten each scan. It
# surfaces when its files next change.
my $QUEUE_SQL = q{
	SELECT album_key, lms_album_id, discogs_release_id, discogs_master_id,
	       match_tier, state, ownership, review_reason,
	       snapshot_artist, snapshot_album_title, snapshot_track_count
	  FROM squeezewax.discogs_match
	 WHERE review_reason IS NOT NULL
	    OR ( match_tier = 'strict' AND discogs_release_id IS NULL )
	 ORDER BY album_key
};

sub beforeRender {
	my ( $class, $params ) = @_;

	$params->{dbReady} = Plugins::SqueezeWax::Schema->isReady ? 1 : 0;
	$params->{dbError} = Plugins::SqueezeWax::Schema->lastError;

	# §15.17 part 4. While Discogs is rejecting the token, §15.15 part 2 skips
	# scan-triggered syncs - so a newly scanned album is identified but never
	# badged, and the queue silently stops growing, for as long as the token
	# stays wrong. The only signal was the settings page's last-error line,
	# which is a different page from the one showing the consequences.
	#
	# Observed on the reference server 2026-09-26: a wrong token left over from
	# earlier testing 401'd every sync, and nothing on this page said so.
	#
	# Required lazily - Async.pm drags in SimpleAsyncHTTP and Timers, and this
	# page only asks it one question.
	require Plugins::SqueezeWax::API::Async;
	$params->{tokenPaused} = Plugins::SqueezeWax::API::Async->tokenRejected ? 1 : 0;

	# _display needs it.
	require Plugins::SqueezeWax::Ownership;

	return unless $params->{dbReady};

	my $rows = Slim::Schema->dbh->selectall_arrayref( $QUEUE_SQL, { Slice => {} } ) || [];

	# One library walk per render, collected first and acted on afterwards.
	# eachAlbum holds a single prepare_cached handle for the length of the walk,
	# so no query may run inside its callback (Importer::_prePass's comment says
	# the same thing about the same iterator).
	#
	# Indexed by album_key, never by lms_album_id: LMS reassigns albums.id on a
	# full rescan (Match.pm _recordNoMatch refreshes it for that reason), so a
	# conflict row's stored id can point at a different album entirely, and
	# re-reading tags by it would show the user the wrong file's tags with
	# nothing to say so.
	my %album;

	Plugins::SqueezeWax::Library->eachAlbum( sub {
		my $a = shift;

		$album{ $a->{album_key} } = $a;

		return 1;
	} );

	# A row whose album is not in the library has nothing to show: no title, no
	# artist, no tags to read. It is not dropped from the table, only from the
	# page. Since §15.46 there is no orphan list to send it to instead (part 8):
	# the scanner's one-to-one relink still recovers a moved album, and one it
	# cannot recover sits unseen, which §2a invariant 4 already accepts.
	my @review = grep { $album{ $_->{album_key} } } @$rows;

	$params->{review} = _reviewList( \@review, \%album, $params->{showTagsFor} );

	$params->{openItems} = scalar @{ $params->{review} };

	return;
}

sub _reviewList {
	my ( $rows, $album, $showFor ) = @_;

	my @out;

	for my $row (@$rows) {
		my $a = $album->{ $row->{album_key} };

		# D3's unmarked fresh conflicts read as conflicts, because that is what
		# they are; the mark is how they are FOUND, not what they mean.
		my $reason = $row->{review_reason} || 'conflict';

		my $item = {
			album_key  => $row->{album_key},
			title      => _display( $a->{title} ),
			artist     => _display( $a->{artist} ),
			reason     => $reason,
			reasonText => string( $REASON_STRING{$reason} || 'PLUGIN_SQUEEZEWAX_REASON_CONFLICT' ),

			# No local track, nothing to tag: the note says so instead of a fix
			# line the user could not follow (§15.46 part 3).
			fixText    => string(
				!$a->{local_tracks}
					? 'PLUGIN_SQUEEZEWAX_QUEUE_STREAMING_NOTE'
					: ( $FIX_STRING{$reason} || 'PLUGIN_SQUEEZEWAX_FIX_CONFLICT' )
			),
		};

		# The list reads NO files. §3a stores no conflict_note, so the only way
		# to show WHICH tags disagree is to read them again - but doing that
		# per render cost up to ~7 s on the reference server, whose library is
		# a CIFS mount: 19-137 ms per file, up to 25 rows x 2 candidates, all
		# of it synchronous in a single-threaded server (decisions §15.17 part
		# 1, measured 2026-09-26). The build that did this was a deviation from
		# the plan's "re-read when opened", recorded at the time with its cost
		# marked INFERRED small. It was not small.
		#
		# So the row carries a flag saying it CAN show tags, and the showtags
		# action reads that one album's candidates - at most two files - when
		# the user asks. The bound went with the behaviour it bounded: there is
		# nothing left to bound.
		$item->{canShowTags} = 1 if $reason eq 'conflict';

		if ( $reason eq 'conflict' && defined $showFor && $showFor eq $row->{album_key} ) {
			$item->{tags} = _readTags($a);

			# The kind's sentence, resolved here rather than in the template. A
			# template mapping three kinds onto three tokens would be a second copy
			# of the vocabulary, and the copy that went stale would be the one
			# nothing compiles. An unrecognised kind falls back to the generic
			# reason text, which is true of every conflict.
			$item->{tags}->{kindText} = string(
				$CONFLICT_KIND_STRING{ $item->{tags}->{kind} || '' }
					|| 'PLUGIN_SQUEEZEWAX_REASON_CONFLICT'
			) if $item->{tags}->{conflict};
		}

		push @out, $item;
	}

	# The reason first, then the album, so items of a kind sit together and a
	# user working through the queue is doing one kind of thinking at a time.
	return [ sort {
		   $a->{reason} cmp $b->{reason}
		|| ( $a->{title} || '' ) cmp( $b->{title} || '' )
	} @out ];
}

# What the album's tags say NOW, for a conflict item.
#
# EXACTLY the read the importer makes, because it is the same sub: since step 8c
# both go through Tags::examineCandidates, of which Importer::_examine is a
# one-line wrapper. The page must show what the importer saw, and a second
# implementation would drift and then show a user tags that do not explain the
# conflict their scan recorded - which is why this used to duplicate the loop and
# now does not. The duplication was already one revision behind before step 8c
# touched it: this copy stopped at `last if %$decision` where the importer stopped
# at `$decision->{id} || $decision->{conflict}`.
#
# Returns what examineCandidates returns, plus `resolved`.
#
# `read` is how many candidate files gave up any tags at all: readTrack catches
# its own failures and returns an empty hash, so zero across every candidate is
# how "the files are no longer readable" looks from here - a folder that moved, a
# disc not mounted, a permission changed. The page distinguishes that from "read
# fine, and the tags no longer disagree", which means the conflict is stale and
# the next scan will clear it.
#
# `kind` is what the page renders distinctly (§15.22): 'in-file', 'cross-ids' or
# 'cross-partial'. The stored review_reason is 'conflict' for all three - one
# reason value, because the column records "these tags are contested" and the
# remedy is the same either way - and what differs is the MESSAGE, which is
# display, computed here from the files as they read right now.
sub _readTags {
	my ($album) = @_;

	return { read => 0 } unless @{ Plugins::SqueezeWax::Tags->tagNames };

	my $decision = Plugins::SqueezeWax::Tags->examineCandidates( $album->{candidates} );

	return {
		%$decision,

		# The tags agree again. The row still says 'conflict' because only the
		# importer clears it and only on a scan (§15.16 part 3) - so the page
		# says as much rather than showing an empty list, which would read as
		# "no tags" and be a different, wrong statement.
		resolved => ( $decision->{read} && !$decision->{conflict} ) ? 1 : 0,
	};
}

1;
