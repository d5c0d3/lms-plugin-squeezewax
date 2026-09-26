package Plugins::SqueezeWax::Queue;

# The review queue and the orphan list: one web page, two lists, four actions.
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
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

use Plugins::SqueezeWax::Library;
use Plugins::SqueezeWax::Match;
use Plugins::SqueezeWax::Schema;
use Plugins::SqueezeWax::Tags;

my $log   = logger('plugin.squeezewax');
my $prefs = preferences('plugin.squeezewax');

# Reason to string token. A reason the user cannot read is not a review queue,
# it is a table of internal vocabulary.
my %REASON_STRING = (
	conflict          => 'PLUGIN_SQUEEZEWAX_REASON_CONFLICT',
	ambiguous         => 'PLUGIN_SQUEEZEWAX_REASON_AMBIGUOUS',
	'artist-disagree' => 'PLUGIN_SQUEEZEWAX_REASON_ARTIST_DISAGREE',
	'artist-absent'   => 'PLUGIN_SQUEEZEWAX_REASON_ARTIST_ABSENT',
	'various-gated'   => 'PLUGIN_SQUEEZEWAX_REASON_VARIOUS_GATED',
	orphan            => 'PLUGIN_SQUEEZEWAX_REASON_ORPHAN',
);

# Async.pm's error vocabulary, mapped onto the strings the settings page already
# uses for the same failures. The same words for the same thing, because a user
# who has just read "Discogs rejected the token" on one page should not meet a
# different sentence for it on the next.
my %SYNC_FAILURE = (
	no_token        => 'PLUGIN_SQUEEZEWAX_SYNC_NO_TOKEN',
	unauthorized    => 'PLUGIN_SQUEEZEWAX_SYNC_FAIL_UNAUTHORIZED',
	already_running => 'PLUGIN_SQUEEZEWAX_SYNC_ALREADY_RUNNING',
	refused         => 'PLUGIN_SQUEEZEWAX_SYNC_REFUSED',
	count_mismatch  => 'PLUGIN_SQUEEZEWAX_SYNC_COUNT_MISMATCH',
	count_unknown   => 'PLUGIN_SQUEEZEWAX_SYNC_COUNT_UNKNOWN',
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

	# Own action names only, each tested explicitly, and saveSettings NOT among
	# them. On the settings page saveSettings has to be the last-tested fallback
	# because the shared form sends it with every submit; here it is simply
	# ignored, which is the stronger position and the one Status.pm takes.
	if ( $params->{rematch} ) {
		# Deferred through $callback, as Settings::_syncNow does
		# (Settings.pm:252-260): the collection fetch is asynchronous and the
		# page cannot render its choices until it returns.
		return _rematch( $class, $client, $params, $callback, \@args, $scanning );
	}
	elsif ( $params->{link} ) {
		_link( $params, $scanning );
	}
	elsif ( $params->{reject} ) {
		_reject( $params, $scanning );
	}
	elsif ( $params->{relink} ) {
		_relink( $params, $scanning );
	}
	elsif ( $params->{showtags} ) {
		_showTags( $params, $scanning );
	}

	$params->{scanning} = $scanning;

	return $class->SUPER::handler( $client, $params, $callback, @args );
}

# ---------------------------------------------------------------------------
# The actions.
#
# Each is a plain function taking its arguments directly (CLAUDE.md's calling
# convention), and each refuses during a scan with the same string the settings
# page uses. Refused rather than queued: someone is looking at the page waiting
# for an answer, and a button that appears to work and then reports nothing is
# worse than one that says why it did not.
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
# Nothing written to the database changes. The re-match screen already decodes
# this way (_choices), so this is that rule applied to the two lists.
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
# makes rematch and reject work on a page with scripting off.
#
# link and relink need two keys and cannot be rescued this way. They answer
# "that album is no longer there" rather than acting on half a request.
sub _actionKey {
	my ( $params, $action ) = @_;

	return _albumKey( $params->{album_key} ) || _albumKey( $params->{$action} );
}

# One album by key, from the iterator, stopping at the first hit.
#
# There is no LMS accessor for this and no per-album query in Library.pm: the
# album_key is derived from the album's own tracks (Library::_finish), so it
# cannot be selected for. The walk is the lookup. Returning false from the
# callback stops it, so the average cost is half a library rather than a whole
# one, and an action is not a render - beforeRender does its own single walk for
# the lists (D6).
sub _albumFor {
	my ($key) = @_;

	my $found;

	Plugins::SqueezeWax::Library->eachAlbum( sub {
		my $album = shift;

		return 1 unless $album->{album_key} eq $key;

		$found = $album;

		return 0;
	} );

	return $found;
}

# Show the tags of ONE conflict row, because the user asked.
#
# Writes nothing, and issues no Discogs request. It only records which album
# the render should expand; _reviewList does the reading, for that album alone.
#
# Refused while scanning like every other action (§15.17 part 1). It touches no
# database and would be harmless mid-scan, but a page where three buttons
# refuse and a fourth quietly works is a page whose rules the user cannot
# learn - and check 8 asserts all of them uniformly.
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

# Confirm: the user has chosen a release from their own collection.
sub _link {
	my ( $params, $scanning ) = @_;

	return if _refused( $params, $scanning );

	my $key = _albumKey( $params->{album_key} );

	if ( !$key ) {
		$params->{warning} = string('PLUGIN_SQUEEZEWAX_QUEUE_NOT_FOUND');
		return;
	}

	my $album = _albumFor($key);

	# The album went away between the render and the press - a rescan while the
	# page sat open. Nothing to snapshot and nothing to link.
	if ( !$album ) {
		$params->{warning} = string('PLUGIN_SQUEEZEWAX_QUEUE_NOT_FOUND');
		return;
	}

	my $ok = Plugins::SqueezeWax::Match->recordManual(
		$album, $params->{release_id}, $params->{master_id} );

	if ( !$ok ) {
		$params->{warning} = string('PLUGIN_SQUEEZEWAX_QUEUE_FAILED');
		return;
	}

	# Stated every time, not once in a help text. The pass is the only writer of
	# ownership (§15.3), and this link changes the badge only by giving the next
	# pass something new to conclude from - so between now and that sync the
	# album looks exactly as it did.
	$params->{actionResult} = string('PLUGIN_SQUEEZEWAX_QUEUE_LINKED') . ' '
		. string('PLUGIN_SQUEEZEWAX_QUEUE_BADGE_LATER');
}

# Reject: delete one row, at the user's explicit request.
sub _reject {
	my ( $params, $scanning ) = @_;

	return if _refused( $params, $scanning );

	# The handler requires the confirm field as well as the page asking. The
	# client-side confirm is a courtesy; this is the guard. A deletion from
	# discogs_match must never be one press away from a mis-click, because it is
	# the one table here that cannot be regenerated.
	if ( !$params->{confirm} ) {
		$params->{warning} = string('PLUGIN_SQUEEZEWAX_QUEUE_CONFIRM_REQUIRED');
		return;
	}

	my $key = _actionKey( $params, 'reject' );

	if ( !$key ) {
		$params->{warning} = string('PLUGIN_SQUEEZEWAX_QUEUE_NOT_FOUND');
		return;
	}

	# rejectRow's own predicate decides whether this row is rejectable at all; a
	# computed item is refused there rather than here, so the rule lives in one
	# place and the page cannot widen it by asking differently.
	if ( !Plugins::SqueezeWax::Match->rejectRow($key) ) {
		$params->{warning} = string('PLUGIN_SQUEEZEWAX_QUEUE_FAILED');
		return;
	}

	$params->{actionResult} = string('PLUGIN_SQUEEZEWAX_QUEUE_REJECTED');
}

# Relink: move an orphaned match onto an album it now describes.
sub _relink {
	my ( $params, $scanning ) = @_;

	return if _refused( $params, $scanning );

	my $old = _albumKey( $params->{album_key} );
	my $new = _albumKey( $params->{target_key} );

	if ( !$old || !$new ) {
		$params->{warning} = string('PLUGIN_SQUEEZEWAX_QUEUE_NOT_FOUND');
		return;
	}

	my $album = _albumFor($new);

	if ( !$album ) {
		$params->{warning} = string('PLUGIN_SQUEEZEWAX_QUEUE_NOT_FOUND');
		return;
	}

	if ( !Plugins::SqueezeWax::Match->relinkOrphan( $old, $new, $album->{album_id} ) ) {
		$params->{warning} = string('PLUGIN_SQUEEZEWAX_QUEUE_FAILED');
		return;
	}

	$params->{actionResult} = string('PLUGIN_SQUEEZEWAX_QUEUE_RELINKED') . ' '
		. string('PLUGIN_SQUEEZEWAX_QUEUE_BADGE_LATER');
}

# ---------------------------------------------------------------------------
# Re-match: choose from the user's own collection.
# ---------------------------------------------------------------------------

# Opening re-match runs a normal collection sync - the same requests the
# settings page's button makes, 1 identity plus ceil(items/100). There is no
# cheaper way: §13.2 requires the collection be discarded when a sync ends, so
# nothing is stored to read back, and that is the decision this pays for rather
# than a shortcoming of this page.
#
# The sync's own guard means a re-match arriving while a scheduled sync is in
# flight is refused with 'already_running' rather than doubling the requests.
#
# It never searches Discogs and never offers a release the user does not own
# (§15.16 part 6). The premise is §14.4's: a well-maintained collection and
# well-tagged rips. A search would let the user link an album to a record they
# do not have, which is a wrong badge that no later sync would correct.
sub _rematch {
	my ( $class, $client, $params, $callback, $args, $scanning ) = @_;

	if ( _refused( $params, $scanning ) ) {
		return _finishRematch( $class, $client, $params, $callback, $args, $scanning );
	}

	my $key = _actionKey( $params, 'rematch' );

	if ( !$key ) {
		$params->{warning} = string('PLUGIN_SQUEEZEWAX_QUEUE_NOT_FOUND');
		return _finishRematch( $class, $client, $params, $callback, $args, $scanning );
	}

	my $token = $prefs->get('discogsToken');

	if ( !defined $token || $token eq '' ) {
		$params->{warning} = string('PLUGIN_SQUEEZEWAX_SYNC_NO_TOKEN');
		return _finishRematch( $class, $client, $params, $callback, $args, $scanning );
	}

	require Plugins::SqueezeWax::API::Async;

	Plugins::SqueezeWax::API::Async->sync( $token, sub {
		my ( $result, $entries ) = @_;

		if ( !$result->{ok} ) {
			my $error = $result->{error} || 'unknown';
			my $token = $SYNC_FAILURE{$error};

			$params->{warning} = $token
				? string($token)
				: sprintf( string('PLUGIN_SQUEEZEWAX_SYNC_FAIL'), $error );

			return _finishRematch( $class, $client, $params, $callback, $args, $scanning );
		}

		# NOT $params->{rematch}: that key is the form field the button sent,
		# and it is still set. Writing the list over it would work, but on a
		# FAILED re-match the field would survive untouched and the template's
		# `IF choices` would fire on a bare 1 - rendering an empty "choose a
		# record" panel instead of the queue. A separate key, so the input and
		# the output of this action cannot be confused for one another.
		$params->{choices} = _choices( $key, $entries );

		_finishRematch( $class, $client, $params, $callback, $args, $scanning );
	} );

	return;
}

sub _finishRematch {
	my ( $class, $client, $params, $callback, $args, $scanning ) = @_;

	$params->{scanning} = $scanning;

	$callback->( $client, $params, $class->SUPER::handler( $client, $params ), @$args );
}

# The collection, rendered once and then dropped.
#
# Title-key matches first, then everything. The title key is Ownership's own
# (§13.10.4's L2), so "the ones that look like this album" means exactly what it
# means to the pass that decided the album was ambiguous in the first place - a
# different rule here would put the album's actual record outside the shortlist
# it was offered.
#
# One row per collection INSTANCE, so a record owned twice appears twice
# (API/Async.pm keys entries on instance_id). De-duplicating would be a small
# lie about what the user owns, and either row links the same release.
#
# The whole list is rendered and filtered client side, so there is no request
# per keystroke against a rate-limited API - and with JavaScript off the full
# list is simply there.
sub _choices {
	my ( $key, $entries ) = @_;

	require Plugins::SqueezeWax::Ownership;

	my $album = _albumFor($key);

	# _titleKey is a plain function in another package; called as one, per
	# CLAUDE.md, the way Importer.pm calls Match::_resolveRelinks.
	my $want = $album
		? Plugins::SqueezeWax::Ownership::_titleKey(
			Plugins::SqueezeWax::Ownership::_decode( $album->{title} ) )
		: '';

	my ( @matching, @rest );

	# Title, then release id. The tie-break is not decoration: the entries
	# arrive as `values %hash`, so without it two records sharing a title come
	# back in whatever order Perl's hash gives them THIS time, and the shortlist
	# reshuffles between renders of the same page. A user comparing two
	# pressings has to be able to look away and look back.
	my @sorted = sort {
		   ( $a->{title} || '' ) cmp( $b->{title} || '' )
		|| ( $a->{id} || 0 ) <=> ( $b->{id} || 0 )
	} @{ $entries || [] };

	for my $entry (@sorted) {
		my $row = {
			release_id => $entry->{id},
			master_id  => $entry->{master_id},
			title      => $entry->{title},
			artists    => join( ', ', @{ $entry->{artists} || [] } ),
			year       => $entry->{year},
			formats    => join( ' / ', @{ $entry->{formats} || [] } ),
			labels     => join( ' / ', @{ $entry->{labels}  || [] } ),

			# Built from the release id. Collection entries carry no page
			# address - basic_information's resource_url is the API one - and
			# Discogs canonicalises the id-only form by redirecting to the
			# slugged page. §9.6 wants a followed hyperlink beside any Discogs
			# data shown, and this is it.
			url => 'https://www.discogs.com/release/' . ( $entry->{id} // '' ),
		};

		if ( $want ne ''
			&& Plugins::SqueezeWax::Ownership::_titleKey( $entry->{title} ) eq $want )
		{
			push @matching, $row;
		}
		else {
			push @rest, $row;
		}
	}

	return {
		album_key => $key,
		album     => $album,
		matching  => \@matching,
		rest      => \@rest,
		total     => scalar(@matching) + scalar(@rest),
	};
}

# ---------------------------------------------------------------------------
# The lists.
# ---------------------------------------------------------------------------

# Every row that is in a queue, by either route.
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
	# Required lazily, as _rematch does - Async.pm drags in SimpleAsyncHTTP and
	# Timers for a page that may never trigger a sync.
	require Plugins::SqueezeWax::API::Async;
	$params->{tokenPaused} = Plugins::SqueezeWax::API::Async->tokenRejected ? 1 : 0;

	# _display needs it, and both lists below use _display.
	require Plugins::SqueezeWax::Ownership;

	return unless $params->{dbReady};

	my $rows = Slim::Schema->dbh->selectall_arrayref( $QUEUE_SQL, { Slice => {} } ) || [];

	# One library walk per render, collected first and acted on afterwards.
	# eachAlbum holds a single prepare_cached handle for the length of the walk,
	# so no query may run inside its callback (Importer::_prePass's comment says
	# the same thing about the same iterator).
	#
	# Indexed by album_key, never by lms_album_id: LMS reassigns albums.id on a
	# full rescan (Match.pm:702-704 exists because of it), so a conflict row's
	# stored id can point at a different album entirely, and re-reading tags by
	# it would show the user the wrong file's tags with nothing to say so.
	my %album;

	Plugins::SqueezeWax::Library->eachAlbum( sub {
		my $a = shift;

		$album{ $a->{album_key} } = $a;

		return 1;
	} );

	my ( @review, @orphans );

	for my $row (@$rows) {
		my $reason = $row->{review_reason} || '';

		if ( $reason eq 'orphan' ) {
			push @orphans, $row;
			next;
		}

		# A row whose album is not in the library and which is not marked
		# 'orphan' has nothing to show: no title, no artist, no tags to read.
		# It is not dropped from the table, only from the page.
		next unless $album{ $row->{album_key} };

		push @review, $row;
	}

	$params->{review}  = _reviewList( \@review, \%album, $params->{showTagsFor} );
	$params->{orphans} = _orphanList( \@orphans, \%album );

	$params->{openItems} = scalar @{ $params->{review} } + scalar @{ $params->{orphans} };

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
			release_id => $row->{discogs_release_id},
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
# The same read the importer makes, through the same two subs, in the same
# order: the primary candidate first, one fallback, never all (Importer::_examine
# and decisions §3). Reusing Tags->decide rather than looking the names up here
# is not tidiness - the page must show what the importer saw, and _lookup
# handles the case and multi-value conventions that differ by format. A second
# implementation would drift and then show a user tags that do not explain the
# conflict their scan recorded.
#
# Returns { read => n, conflict => [...] }. `read` is how many candidate files
# gave up any tags at all: readTrack catches its own failures and returns an
# empty hash (Tags.pm:290-297), so zero across every candidate is how "the files
# are no longer readable" looks from here - a folder that moved, a disc not
# mounted, a permission changed. The page distinguishes that from "read fine,
# and the tags no longer disagree", which means the conflict is stale and the
# next scan will clear it.
sub _readTags {
	my ($album) = @_;

	return { read => 0 } unless @{ Plugins::SqueezeWax::Tags->tagNames };

	my $read     = 0;
	my $decision = {};

	for my $url ( @{ $album->{candidates} || [] } ) {
		my $tags = Plugins::SqueezeWax::Tags->readTrack($url);

		$read++ if %$tags;

		$decision = Plugins::SqueezeWax::Tags->decide($tags);

		# Anything but "no configured tag present" is an answer, exactly as
		# _examine treats it.
		last if %$decision;
	}

	return {
		read     => $read,
		conflict => $decision->{conflict},

		# The tags agree again. The row still says 'conflict' because only the
		# importer clears it and only on a scan (§15.16 part 3) - so the page
		# says as much rather than showing an empty list, which would read as
		# "no tags" and be a different, wrong statement.
		resolved => ( $read && !$decision->{conflict} ) ? 1 : 0,
	};
}

# The albums an orphan may be moved onto, as the template needs them: the key
# to submit, and a title and artist a human can read (§15.17 part 6). Sorted on
# the DECODED title, so the order is the one the user sees.
sub _forDisplay {
	my ($albums) = @_;

	my @out = map { {
		album_key => $_->{album_key},
		title     => _display( $_->{title} ),
		artist    => _display( $_->{artist} ),
	} } @{ $albums || [] };

	return [ sort { ( $a->{title} || '' ) cmp( $b->{title} || '' ) } @out ];
}

sub _orphanList {
	my ( $rows, $album ) = @_;

	return [] unless @$rows;

	# Which albums an orphan may be moved onto (§15.17 part 2).
	#
	# The rule used to be "a key miss - no row in EITHER table", copied from
	# _prePass. That is right for the SCANNER, which decides during the scan,
	# but wrong for this page, which renders afterwards: the same scan that
	# orphans a row also examines every current album and gives each one a row -
	# a match row if its tags identify it, a no-match row if they do not. So by
	# render time nothing was ever eligible, and the page could not offer a
	# relink at all. Report §2.2 proved it three ways offline and once by
	# accident on hardware, where an album with the same artist, title AND track
	# count was silently withheld.
	#
	# The rule that works is about what a row COSTS to lose, not whether one
	# exists. An album is eligible when everything it carries is regenerable:
	#   - a strict discogs_no_match row - regenerable in full, and relinkOrphan
	#     deletes it so §2a invariant 1 holds when the match row lands;
	#   - an ownership-only or reason-only discogs_match row - the three NULLs
	#     of §15.16 part 9, which the next sync rebuilds;
	#   - or no rows at all.
	# An album carrying its own IDENTIFICATION is not eligible: its tags already
	# rebuild its match (§15.5), so the orphan is not needed there and moving it
	# would overwrite a decision.
	#
	# The ineligible fits are collected too, because the page has to tell those
	# two cases apart: "nothing fits" and "things fit, but they identify
	# themselves" are different facts about the library, and saying the first
	# when the second is true is a lie (§15.17 part 3).
	my $taken   = Plugins::SqueezeWax::Match->snapshotRows;
	my $noMatch = Plugins::SqueezeWax::Match->noMatchKeys;

	my %hasRow = map { $_->{album_key} => $_ } @$taken;

	my ( %fits, %identified );

	for my $key ( keys %$album ) {
		my $a = $album->{$key};

		my $fit = Plugins::SqueezeWax::Match::_fitKey(
			$a->{artist}, $a->{title}, $a->{local_tracks} );

		next unless defined $fit;

		# An identification of its own. Not a target, but it DOES fit, and the
		# message depends on knowing that.
		if ( defined $hasRow{$key} && defined $hasRow{$key}{match_tier} ) {
			push @{ $identified{$fit} }, $a;

			next;
		}

		push @{ $fits{$fit} }, $a;
	}

	my @out;

	for my $row (@$rows) {
		my $fit = Plugins::SqueezeWax::Match::_fitKey(
			$row->{snapshot_artist}, $row->{snapshot_album_title},
			$row->{snapshot_track_count} );

		# Every candidate, not only the unambiguous one. The scanner's automatic
		# relink takes only a one-to-one fit (§15.12 part 2) and leaves the rest
		# untouched - which is precisely the case this list exists for, so
		# offering the user a choice between two is the whole point (§15.5 part
		# 4, D4).
		my @candidates = defined $fit ? @{ $fits{$fit} || [] } : ();
		my @ineligible = defined $fit ? @{ $identified{$fit} || [] } : ();

		push @out, {
			album_key  => $row->{album_key},
			release_id => $row->{discogs_release_id},
			match_tier => $row->{match_tier},
			artist     => _display( $row->{snapshot_artist} ),
			title      => _display( $row->{snapshot_album_title} ),
			tracks     => $row->{snapshot_track_count},
			url        => 'https://www.discogs.com/release/'
				. ( $row->{discogs_release_id} // '' ),

			# D4: an orphan that fits nothing can only be rejected. Relinking it
			# to an album of the user's choosing is recorded as future work,
			# because an arbitrary relink is a manual match by another name and
			# would want the re-match flow rather than this list.
			candidates => _forDisplay( \@candidates ),

			# Albums that fit but identify themselves. Only ever shown when
			# there are no eligible targets at all - otherwise the user is
			# choosing, not being told why they cannot (§15.17 part 3).
			identified => _forDisplay( \@ineligible ),
		};
	}

	return [ sort { ( $a->{title} || '' ) cmp( $b->{title} || '' ) } @out ];
}

1;
