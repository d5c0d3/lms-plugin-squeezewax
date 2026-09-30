#!/usr/bin/env perl
#
# Offline exercise of Plugins::SqueezeWax::Plugin's SYNC TRIGGERS.
#
# Why this file exists: decisions §15.15 part 1 removed the scheduled sync -
# the interval pref, its validator, the startup sync and the interval re-arm
# at the top of _syncTick. What is left has to be exactly one trigger
# (['rescan','done'], debounced) plus the settings-page button, and the thing
# that would go wrong silently is a timer that is still armed somewhere. A
# removal is only as good as the assertion that it stayed removed.
#
# Plugin.pm had no suite before this. It is the file that decides WHEN the
# plugin talks to Discogs, so "no timer is armed" is worth a test even though
# nothing here is complicated.
#
# The boundaries are stubbed and observed, never the subs under test:
#   Slim::Utils::Timers::setTimer / killTimers   what is armed, and when
#   Slim::Control::Request::subscribe            what is subscribed to
#   Plugins::SqueezeWax::API::Async->sync        whether a sync actually starts
#   the prefs object's migrate()                 the recorded migration
#
# Usage: scripts/plugin-check.pl

use strict;
use warnings;

use Config;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;

BEGIN {
	my $libPath = "$Bin/../refs/slimserver";
	die "refs/slimserver not found at $libPath\n" unless -d $libPath;

	my $arch = $Config::Config{archname};
	$arch =~ s/^i[3456]86-/i386-/;
	$arch =~ s/gnu-//;

	my $perlmajorversion = $Config{version};
	$perlmajorversion =~ s/\.\d+$//;

	unshift @INC, grep { -d } (
		"$libPath/CPAN/arch/$perlmajorversion/$arch",
		"$libPath/CPAN/arch/$perlmajorversion/$arch/auto",
		"$libPath/CPAN/arch/$perlmajorversion",
		"$libPath/lib",
		"$libPath/CPAN",
		$libPath,
	);
}

# A controllable clock for the skip rule's window. Installed before Plugin.pm
# is compiled, so its time() calls resolve here; undef means the real clock.
our $NOW;
BEGIN { *CORE::GLOBAL::time = sub () { defined $main::NOW ? $main::NOW : CORE::time() } }

our @TIMERS;      # every setTimer call
our @KILLS;       # every killTimers call
our @SUBSCRIBED;  # every Slim::Control::Request::subscribe call
our @SYNCS;       # every Async->sync call
our %PREFS;
our %MIGRATIONS;  # version => coderef, as recorded by the prefs stub
our %CHANGES;     # prefname => coderef, likewise
our @WRITES;      # ordered pref writes
our $SCANNING = 0;
our $REJECTED = 0;
our $SKIP_FIRST = 1;
our @SKIPS;
our @CLEARED;

BEGIN {
	$INC{'Slim/Plugin/Base.pm'}      = 1;
	$INC{'Slim/Control/Request.pm'}  = 1;
	$INC{'Slim/Utils/Log.pm'}        = 1;
	$INC{'Slim/Utils/Prefs.pm'}      = 1;
	$INC{'Slim/Utils/Timers.pm'}     = 1;
	$INC{'Slim/Music/Import.pm'}     = 1;
	$INC{'Slim/Schema.pm'}           = 1;
	$INC{'Slim/Music/Info.pm'}       = 1;
	$INC{'Slim/Formats.pm'}          = 1;
	$INC{'Slim/Utils/Scheduler.pm'}  = 1;

	no strict 'refs';

	*{'Slim::Plugin::Base::initPlugin'} = sub { 1 };

	# refs/slimserver/Slim/Control/Request.pm:788-809 - subscribe keys
	# listeners by the stringified coderef.
	*{'Slim::Control::Request::subscribe'} = sub {
		push @SUBSCRIBED, { cb => $_[0], filter => $_[1] };
		return 1;
	};

	# refs/slimserver/Slim/Utils/Timers.pm:66-120 - setTimer appends, so a
	# self-rescheduling timer must killTimers itself first.
	*{'Slim::Utils::Timers::setTimer'} = sub {
		push @TIMERS, { obj => $_[0], when => $_[1], cb => $_[2] };
		return 1;
	};
	*{'Slim::Utils::Timers::killTimers'} = sub {
		push @KILLS, { obj => $_[0], cb => $_[1] };
		return 1;
	};

	*{'Slim::Music::Import::stillScanning'} = sub { $main::SCANNING };

	*{'Slim::Utils::Log::addLogCategory'} = sub { Test::StubLogger->new };
	*{'Slim::Utils::Log::logger'}         = sub { Test::StubLogger->new };
	*{'Slim::Utils::Log::logError'}       = sub { };
	*{'Slim::Utils::Log::import'}         = sub {
		my $caller = caller;
		no strict 'refs';
		*{"${caller}::logger"}   = \&Slim::Utils::Log::logger;
		*{"${caller}::logError"} = \&Slim::Utils::Log::logError;
	};

	*{'Slim::Utils::Prefs::preferences'} = sub { Test::StubPrefs->new };
	*{'Slim::Utils::Prefs::import'}      = sub {
		my $caller = caller;
		no strict 'refs';
		*{ $caller . '::preferences' } = \&Slim::Utils::Prefs::preferences;
	};

	*{'main::SCANNER'}   = sub () { 0 };
	# INFOLOG is ON, and is_info below returns true with it, so every
	# `main::INFOLOG && $log->is_info && $log->info(...)` expression is
	# EVALUATED rather than short-circuited away (stub audit 2026-09-24, entry
	# 5.3 / 4). Those expressions build strings from live counters; a summary
	# that dies while being built is a defect no suite could see while this was
	# 0, and the ownership pass's counts are what step 8 will size its queue
	# from.
	*{'main::INFOLOG'}   = sub () { 1 };
	*{'main::DEBUGLOG'}  = sub () { 0 };
	*{'main::ISWINDOWS'} = sub () { 0 };
	# The web-UI branch of initPlugin is Settings.pm's business and has its own
	# suite; this one is about the headless path, which is where the triggers
	# have to work (decisions §15.12 part 3).
	*{'main::WEBUI'}     = sub () { 0 };
}

{
	package Test::StubPrefs;
	sub new { bless {}, shift }
	sub get { return $PREFS{ $_[1] } }
	# Dispatches onchange, as Slim/Utils/Prefs/Base.pm:91 does, and suppresses
	# a scalar set that changes nothing (:94-97).
	#
	# Until 2026-09-24 this was a plain hash write and the assertions fired the
	# registered callback BY HAND - so they proved the callback's body and not
	# that anything was wired to it. Deleting the setChange registration in
	# Plugin.pm would have left this suite green (stub audit, entry 2.2).
	sub set {
		my ( $self, $pref, $new ) = @_;

		my $old = $PREFS{$pref};

		return 1 if !ref $new
			&& defined $new
			&& defined $old
			&& $new eq $old;

		$PREFS{$pref} = $new;

		push @WRITES, $pref;

		if ( my $cb = $CHANGES{$pref} ) {
			$cb->( $pref, $new );
		}

		return 1;
	}
	sub init {
		my ( $self, $defaults ) = @_;
		for my $k ( keys %{ $defaults || {} } ) {
			$PREFS{$k} = $defaults->{$k} unless exists $PREFS{$k};
		}
		return 1;
	}
	# Recorded rather than run: the assertions below drive each migration
	# against a prefs store that actually contains the dead key.
	sub migrate     { $MIGRATIONS{ $_[1] } = $_[2]; return 1 }
	sub setValidate { $main::VALIDATED{ $_[2] } = $_[1]; return 1 }
	# Recorded, so the assertions can fire the registered callback the way
	# Slim/Utils/Prefs/Base.pm:91 does when the pref is written.
	sub setChange   { my ( $self, $cb, @prefs ) = @_; $CHANGES{$_} = $cb for @prefs; return 1 }
	sub remove      { delete $PREFS{ $_[1] }; delete $PREFS{ '_ts_' . $_[1] }; return 1 }
}

our @LOG;

{
	package Test::StubLogger;
	sub new      { bless {}, shift }
	sub error    { } sub warn { } sub debug { }
	sub info     { shift; push @main::LOG, "@_"; return }
	sub is_info  { 1 } sub is_debug { 0 }
}

our %VALIDATED;

# The marker (decisions §15.18 part 7) is the one database read Plugin.pm
# makes, and only for the skip rule. Driven from $main::MARKER.
our $MARKER;

# discogs_meta, likewise driven from here (decisions §15.24). %META is the
# stored side of the logic-version comparison; $READY is the schema's.
our %META;
our $READY = 1;
our @METAWRITES;

{
	package Plugins::SqueezeWax::Schema;
	sub init { 1 }
	sub syncState { $main::MARKER }
	sub isReady { $main::READY }
	sub meta { return $main::READY ? $main::META{ $_[1] } : undef }
	sub setMeta {
		return undef unless $main::READY;
		push @main::METAWRITES, [ $_[1], $_[2] ];
		$main::META{ $_[1] } = $_[2];
		return 1;
	}
}
BEGIN { $INC{'Plugins/SqueezeWax/Schema.pm'} = 1 }

BEGIN {
	$INC{'Plugins/SqueezeWax/API/Async.pm'} = 1;
	no strict 'refs';
	*{'Plugins::SqueezeWax::API::Async::sync'} = sub {
		my ( $class, $token, $cb ) = @_;
		push @SYNCS, $token;
		return 1;
	};

	# The rejection pause (§15.15 part 2). Async owns the state; Plugin.pm only
	# consults it, so the suite drives it from here.
	*{'Plugins::SqueezeWax::API::Async::tokenRejected'} = sub { $main::REJECTED };
	*{'Plugins::SqueezeWax::API::Async::clearTokenRejected'} = sub {
		push @CLEARED, 1;
		$main::REJECTED = 0;
		return;
	};
	*{'Plugins::SqueezeWax::API::Async::noteSkipped'}   = sub {
		push @SKIPS, 1;
		return $main::SKIP_FIRST--> 0 ? 1 : 0;
	};
}

# The master derive job (build-order step 8c). Stubbed, not loaded: the real
# module pulls in SimpleAsyncHTTP, which reaches the OSDetect/Unicode chain every
# stub in this file exists to cut, and what is under test here is WHETHER the
# trigger fires - the job's own behaviour is scripts/derive-check.pl's.
our @ARMED;

BEGIN {
	$INC{'Plugins/SqueezeWax/Derive.pm'} = 1;
	no strict 'refs';
	*{'Plugins::SqueezeWax::Derive::arm'} = sub { push @ARMED, 1; return 1 };
}

# Match.pm is stubbed for the same reason Derive.pm is: the real module pulls in
# Library.pm and Slim::Music::Import, and what is under test here is the
# DECISION - whether the logic-version check invalidates, and whether it records
# the new version afterwards. invalidateStrict's own behaviour is
# scripts/match-check.pl's.
#
# $INVALIDATED stands in for _writeOk: undef is the refusal Match.pm:105 returns
# when a scan is running or the schema is unusable, which is the case §15.24's
# "record only on success" rule exists for.
our @INVALIDATIONS;
our $INVALIDATE_RETURN = 503;
our $HAS_ROWS          = 1;

BEGIN {
	$INC{'Plugins/SqueezeWax/Match.pm'} = 1;
	no strict 'refs';
	*{'Plugins::SqueezeWax::Match::invalidateStrict'} = sub {
		push @INVALIDATIONS, 1;
		return $main::INVALIDATE_RETURN;
	};
	*{'Plugins::SqueezeWax::Match::hasAnyRow'} = sub { $main::HAS_ROWS };
}

# Menu.pm is stubbed for the reason Derive.pm and Match.pm are: the real module
# pulls in Slim::Menu::AlbumInfo, which reaches the Strings/Prefs/Unicode chain
# every stub in this file exists to cut. What is under test HERE is that
# initPlugin registers the menu at all - what the providers return is
# scripts/menu-check.pl's, which drives the real Slim::Menu classes.
our @MENU_INIT;

BEGIN {
	$INC{'Plugins/SqueezeWax/Menu.pm'} = 1;
	no strict 'refs';
	*{'Plugins::SqueezeWax::Menu::init'} = sub { push @MENU_INIT, 1; return };
}

# View.pm, stubbed for the same reason: it loads Slim::Music::VirtualLibraries
# and Slim::Menu::BrowseLibrary. What is under test here is WHERE a rebuild is
# triggered from - registration and the build itself are menu-check.pl's.
our @VIEW_INIT;
our @REBUILDS;

BEGIN {
	$INC{'Plugins/SqueezeWax/View.pm'} = 1;
	no strict 'refs';
	*{'Plugins::SqueezeWax::View::init'}    = sub { push @VIEW_INIT, 1; return };
	*{'Plugins::SqueezeWax::View::rebuild'} = sub { push @REBUILDS, 1; return 1 };
}

my $incdir;

BEGIN {
	$incdir = tempdir( CLEANUP => 1 );
	mkdir "$incdir/Plugins";
	symlink "$Bin/../SqueezeWax", "$incdir/Plugins/SqueezeWax"
		or die "could not link the plugin into $incdir: $!\n";
	unshift @INC, $incdir;
}

require Plugins::SqueezeWax::Plugin;

my $P = 'Plugins::SqueezeWax::Plugin';

# The same store Plugin.pm holds: Slim::Utils::Prefs::preferences returns a
# fresh object each call, but every one of them reads and writes %PREFS and
# consults %CHANGES, so a write through this handle is a write through theirs.
my $prefs_under_test = Test::StubPrefs->new;

sub reset_state {
	@TIMERS = ();
	@KILLS  = ();
	@SYNCS  = ();
	@SUBSCRIBED = ();
	@SKIPS    = ();
	@CLEARED  = ();
	@WRITES   = ();
	$SCANNING = 0;
	$REJECTED = 0;
	$SKIP_FIRST = 1;
	$MARKER   = undef;
	$NOW      = undef;
	@ARMED    = ();
	@REBUILDS = ();
	@VIEW_INIT = ();
	@MENU_INIT = ();
	@LOG      = ();
	@INVALIDATIONS = ();
	@METAWRITES    = ();
	%META             = ();
	$READY            = 1;
	$HAS_ROWS         = 1;
	$INVALIDATE_RETURN = 503;
}

# ---------------------------------------------------------------------------
# No scheduled sync (§15.15 part 1)
# ---------------------------------------------------------------------------

diag('§15.15 part 1: the only automatic trigger is a finished scan');

{
	reset_state();

	Plugins::SqueezeWax::Plugin::_initSync();

	is( scalar @SUBSCRIBED, 1, 'init subscribes exactly one request listener' );
	is_deeply( $SUBSCRIBED[0]{filter}, [ ['rescan'], ['done'] ],
		'  ...to [[rescan],[done]] - scan FINISH, not scan start (§15.2)' );

	is( scalar @TIMERS, 0,
		'init arms NO timer: there is no startup sync and no interval (§15.15)' );
}

# The pref and its validator are gone, and nothing re-creates them.
{
	ok( !exists $PREFS{discogsSyncInterval},
		'discogsSyncInterval is not initialised as a default any more' );
	ok( !exists $VALIDATED{discogsSyncInterval},
		'  ...and no validator is registered for it' );
}

# ---------------------------------------------------------------------------
# The migration that removes it from existing prefs files
# ---------------------------------------------------------------------------

diag('the migration off the interval pref');

{
	ok( $MIGRATIONS{2}, 'a migrate(2) is registered' );

	local %PREFS = (
		discogsSyncInterval     => 86400,
		_ts_discogsSyncInterval => 1789890612,
		discogsToken            => 'keep-me',
		discogsLastSyncError    => 'no_response',
	);

	$MIGRATIONS{2}->( Test::StubPrefs->new );

	ok( !exists $PREFS{discogsSyncInterval},
		'  ...and it removes discogsSyncInterval from an existing prefs file' );
	ok( !exists $PREFS{_ts_discogsSyncInterval},
		'  ...along with its _ts_ twin (Slim/Utils/Prefs/Base.pm:242-258)' );
	is( $PREFS{discogsToken},      'keep-me',   '  ...and touches nothing else' );
	is( $PREFS{discogsLastSyncError}, 'no_response', '  ...including the last sync error' );
}

# ---------------------------------------------------------------------------
# The migration off the last-synced prefs (decisions §15.18 part 7)
# ---------------------------------------------------------------------------

diag('§15.18 part 7: last synced is the marker row, not a pref');

{
	ok( $MIGRATIONS{3}, 'a migrate(3) is registered' );

	local %PREFS = (
		discogsLastSynced        => 1790085746,
		_ts_discogsLastSynced    => 1790085746,
		discogsLastSyncItems     => 203,
		_ts_discogsLastSyncItems => 1790085746,
		discogsLastSyncError     => 'no_response',
		discogsToken             => 'keep-me',
	);

	$MIGRATIONS{3}->( Test::StubPrefs->new );

	ok( !exists $PREFS{discogsLastSynced},    '  ...and it removes discogsLastSynced' );
	ok( !exists $PREFS{discogsLastSyncItems}, '  ...and discogsLastSyncItems' );
	ok( !exists $PREFS{_ts_discogsLastSynced} && !exists $PREFS{_ts_discogsLastSyncItems},
		'  ...along with their _ts_ twins' );
	is( $PREFS{discogsLastSyncError}, 'no_response',
		'  ...but keeps discogsLastSyncError, which is the server\'s alone' );
	is( $PREFS{discogsToken}, 'keep-me', '  ...and touches nothing else' );
}

{
	ok( !exists $PREFS{discogsLastSynced},
		'discogsLastSynced is not initialised as a default any more' );
	ok( !exists $PREFS{discogsLastSyncItems},
		'  ...nor discogsLastSyncItems' );
	ok( exists $PREFS{discogsLastSyncError},
		'  ...while discogsLastSyncError still is' );
}

# ---------------------------------------------------------------------------
# rescan-done still arms exactly one debounced sync
# ---------------------------------------------------------------------------

diag('the one remaining automatic trigger');

{
	reset_state();

	my $before = time();
	Plugins::SqueezeWax::Plugin::_rescanDone();

	is( scalar @TIMERS, 1, 'rescan-done arms exactly one timer' );
	is( scalar @REBUILDS, 1,
		'  ...and rebuilds the owned view at once: after a wipe every album id in it is stale' );
	is( scalar @KILLS,  1, '  ...having killed any already armed first' );
	is( $KILLS[0]{cb}, $TIMERS[0]{cb},
		'  ...killing the same coderef it then arms' );
	ok( !defined $TIMERS[0]{obj} && !defined $KILLS[0]{obj},
		'  ...with an undef $obj, which is what makes the kill able to find it' );

	# DEBOUNCE_AFTER_RESCAN is 60; assert the debounce exists and is in the
	# right ballpark rather than pinning a product number in two places.
	my $delay = $TIMERS[0]{when} - $before;
	ok( $delay >= 30 && $delay <= 300,
		"  ...debounced rather than immediate (${delay}s)" );
}

{
	reset_state();

	# A scan can emit ['rescan','done'] more than once. Each arrival must
	# restart the wait, not stack a second sync behind the first - observed on
	# hardware 2026-09-22, three notifications in 2.7s producing one sync.
	Plugins::SqueezeWax::Plugin::_rescanDone() for 1 .. 3;

	is( scalar @KILLS, 3, 'three notifications kill three times' );
	is( scalar @TIMERS, 3, '  ...and arm three times' );
	is( $TIMERS[0]{cb}, $TIMERS[2]{cb},
		'  ...always the same coderef, so only the last one survives' );
}

# ---------------------------------------------------------------------------
# _syncTick re-arms nothing
# ---------------------------------------------------------------------------

diag('the tick is terminal: every path out re-arms nothing');

{
	reset_state();
	$PREFS{discogsToken} = 'a-token';

	Plugins::SqueezeWax::Plugin::_syncTick();

	is( scalar @SYNCS, 1, 'a tick with a token starts one sync' );
	is( $SYNCS[0], 'a-token', '  ...with the stored token' );
	is( scalar @TIMERS, 0,
		'  ...and arms NOTHING - the interval re-arm is gone (§15.15 part 1)' );
}

{
	reset_state();
	delete $PREFS{discogsToken};

	Plugins::SqueezeWax::Plugin::_syncTick();

	is( scalar @SYNCS,  0, 'a tick with no token starts no sync' );
	is( scalar @TIMERS, 0, '  ...and re-arms nothing' );
}

{
	reset_state();
	$PREFS{discogsToken} = 'a-token';
	$PREFS{discogsToken} = '';

	Plugins::SqueezeWax::Plugin::_syncTick();

	is( scalar @SYNCS,  0, 'an empty token is no token' );
	is( scalar @TIMERS, 0, '  ...and re-arms nothing' );
}

{
	reset_state();
	$PREFS{discogsToken} = 'a-token';
	local $main::SCANNING = 1;

	Plugins::SqueezeWax::Plugin::_syncTick();

	is( scalar @SYNCS,  0, 'a tick while a scan is running defers' );
	is( scalar @TIMERS, 0,
		'  ...and re-arms nothing: that scan\'s own rescan-done is the net' );
}

# ---------------------------------------------------------------------------
# The rejection pause (§15.15 part 2)
# ---------------------------------------------------------------------------

diag('a rejected token stops scan-triggered syncs, not the button');

{
	reset_state();
	$PREFS{discogsToken} = 'a-token';
	$REJECTED = 1;

	Plugins::SqueezeWax::Plugin::_syncTick();

	is( scalar @SYNCS, 0,
		'a scan-triggered sync is skipped while the token is rejected' );
	is( scalar @SKIPS, 1, '  ...and the skip is recorded once for logging' );
	is( scalar @TIMERS, 0, '  ...and nothing is re-armed' );
}

{
	reset_state();
	$PREFS{discogsToken} = 'a-token';
	$REJECTED = 1;

	Plugins::SqueezeWax::Plugin::_syncTick() for 1 .. 3;

	is( scalar @SYNCS, 0, 'three scans while rejected start no syncs' );
	is( scalar @SKIPS, 3, '  ...each consulting the once-only marker' );
}

{
	reset_state();
	$PREFS{discogsToken} = 'a-token';
	$REJECTED = 0;

	Plugins::SqueezeWax::Plugin::_syncTick();

	is( scalar @SYNCS, 1, 'once the rejection clears, a scan syncs again' );
	is( scalar @SKIPS, 0, '  ...with no skip recorded' );
}

# The pause is consulted BEFORE the scanning check, so a rejected token is
# reported as the reason rather than being masked by a scan in progress.
{
	reset_state();
	$PREFS{discogsToken} = 'a-token';
	$REJECTED = 1;
	local $main::SCANNING = 1;

	Plugins::SqueezeWax::Plugin::_syncTick();

	is( scalar @SKIPS, 1,
		'a rejected token is the reported reason even while a scan runs' );
	is( scalar @SYNCS, 0, '  ...and no sync starts either way' );
}

# ---------------------------------------------------------------------------
# A new token is a new chance (§15.15 parts 2 and 3)
# ---------------------------------------------------------------------------
#
# The last error and the rejection pause both describe the OLD token's last
# conversation with Discogs. Leaving either in place after the user has fixed
# the thing they describe is how a fixed server goes on looking broken - which
# is how a stale `no_response` misled a reader of this project's own logs on
# 2026-09-22.

diag('changing the token clears what described the old one');

{
	reset_state();

	ok( $CHANGES{discogsToken}, 'a change handler is registered for the token' );
	ok( !$CHANGES{discogsLastSyncError},
		'  ...and not for anything it writes itself, which would recurse' );
}

{
	reset_state();
	$PREFS{discogsLastSyncError} = 'unauthorized';
	$REJECTED = 1;

	# Written through the store, not fired by hand: that is the difference
	# between proving the callback's body and proving it is WIRED.
	$prefs_under_test->set( 'discogsToken', 'a-new-token' );

	is( $PREFS{discogsLastSyncError}, '',
		'changing the token clears the last sync error' );
	is( scalar @CLEARED, 1, '  ...and clears the rejection pause' );
	ok( !$REJECTED, '  ...so the next finished scan syncs again' );
}

# The username describes the OLD token (build-order step 9 §4). A new token is
# as often a different account as the same one, and a settings page linking to a
# stranger's collection is worse than one linking to discogs.com.
{
	reset_state();
	$PREFS{discogsUsername} = 'deschman';

	$prefs_under_test->set( 'discogsToken', 'a-different-token' );

	is( $PREFS{discogsUsername}, '',
		'changing the token clears the stored Discogs username' );
}

{
	reset_state();
	$PREFS{discogsLastSyncError} = 'unauthorized';

	$prefs_under_test->set( 'discogsToken', 'another-token' );

	# The marker is a table row now (§15.18 part 7), which this hook has no
	# handle on. What is left to pin is that the hook writes the error and
	# nothing else - a last-synced time is not the old token's to take away.
	is_deeply( [ grep { $_ ne 'discogsToken' } @WRITES ], ['discogsLastSyncError'],
		'  ...and writes the error pref and nothing else' );
}

# The registration itself, not just its body. Deleting the setChange line in
# Plugin.pm used to leave this suite green (stub audit, entry 2.2).
{
	reset_state();
	$PREFS{discogsLastSyncError} = 'unauthorized';
	$REJECTED = 1;

	$prefs_under_test->set( 'discogsToken', 'yet-another' );

	ok( ( grep { $_ eq 'discogsToken' } @WRITES ),
		'writing the token really writes it' );
	is( scalar @CLEARED, 1,
		'  ...and the hook Plugin.pm registered fires from the WRITE' );
}

# Suppression, so an unchanged token is not a "new chance".
{
	reset_state();
	$PREFS{discogsToken}         = 'same';
	$PREFS{discogsLastSyncError} = 'unauthorized';
	$REJECTED = 1;

	$prefs_under_test->set( 'discogsToken', 'same' );

	is( scalar @WRITES, 0, 'saving an unchanged token is suppressed' );
	is( scalar @CLEARED, 0, '  ...so it does not clear a live rejection' );
	is( $PREFS{discogsLastSyncError}, 'unauthorized',
		'  ...nor the error that explains it' );
}

# ---------------------------------------------------------------------------
# The skip rule (decisions §15.18 part 8)
# ---------------------------------------------------------------------------
#
# The fallback skips only for a 'scan' marker written between the previous
# scan's rescan-done and this one's. Every other case syncs: the rule errs
# toward syncing. The window is driven through the real _initSync and
# _rescanDone, and the marker is placed relative to the times they recorded, so
# the assertions do not depend on the wall clock moving; $NOW drives it.

diag('§15.18 part 8: the fallback skips only when this scan synced');

# Open a window: init at 1000, one rescan-done at 1100. Returns both times.
sub open_window {
	$NOW = 1000;
	Plugins::SqueezeWax::Plugin::_initSync();

	$NOW = 1100;
	Plugins::SqueezeWax::Plugin::_rescanDone();

	return ( 1000, 1100 );
}

{
	reset_state();
	$PREFS{discogsToken} = 'a-token';

	my ( $init, $done ) = open_window();
	$MARKER = { last_synced => $done, items => 203, source => 'scan' };

	Plugins::SqueezeWax::Plugin::_syncTick();

	is( scalar @SYNCS, 0, "a 'scan' marker inside the window skips the fallback" );
	ok( ( grep { /scan already synced.*marker at $done/ } @LOG ),
		'  ...and logs why, with the marker\'s time' );

	# Step 8c, and a DEVIATION from its plan, which triggers the derive job from
	# _syncDone alone. On a server whose scan-time sync works - the reference
	# server - this skip is the ONLY path taken after a scan, so _syncDone is
	# never reached and the job would never run. Group A would ship as dead as
	# the master arm it exists to wake up.
	is( scalar @ARMED, 1,
		'  ...and still arms the master derive job: a sync DID complete, in the scanner' );

	# And the owned view, for the same reason and on the same path: the pass
	# that changed ownership ran in the scanner, so the server's view is the one
	# that is stale. Two rebuilds here - one from the rescan-done that opened
	# the window, one from this tick - which is idempotent local SQL.
	is( scalar @REBUILDS, 2,
		'  ...and rebuilds the owned view, from rescan-done and from the tick' );
}

{
	reset_state();
	$PREFS{discogsToken} = 'a-token';

	my ( $init, $done ) = open_window();
	$MARKER = { last_synced => $done, items => 203, source => 'server' };

	Plugins::SqueezeWax::Plugin::_syncTick();

	is( scalar @SYNCS, 1,
		"a 'server' marker inside the window does NOT skip - a manual sync saw the library before this scan" );
}

{
	reset_state();
	$PREFS{discogsToken} = 'a-token';

	open_window();
	$MARKER = undef;

	Plugins::SqueezeWax::Plugin::_syncTick();

	is( scalar @SYNCS, 1, 'no marker does not skip' );
}

{
	reset_state();
	$PREFS{discogsToken} = 'a-token';

	my ( $init, $done ) = open_window();

	# Written at init or before: a marker from a previous run of this server,
	# whose rescan-done this process never saw.
	$MARKER = { last_synced => $init - 1, items => 203, source => 'scan' };

	Plugins::SqueezeWax::Plugin::_syncTick();

	is( scalar @SYNCS, 1, 'a marker from before initPlugin does not skip' );
}

{
	reset_state();
	$PREFS{discogsToken} = 'a-token';

	my ( $init, $done ) = open_window();

	# After this rescan-done: not written during the scan that just finished.
	$MARKER = { last_synced => $done + 30, items => 203, source => 'scan' };

	Plugins::SqueezeWax::Plugin::_syncTick();

	is( scalar @SYNCS, 1, "a 'scan' marker after the window does not skip" );
}

{
	reset_state();
	$PREFS{discogsToken} = 'a-token';

	# Two scans. The first one's marker lies in the FIRST window; the second
	# scan did not sync (its importer did not run), so its tick must sync.
	my ( $init, $first ) = open_window();
	Plugins::SqueezeWax::Plugin::_syncTick();    # closes the first window
	@SYNCS = ();

	$NOW = 1300;
	Plugins::SqueezeWax::Plugin::_rescanDone();

	$MARKER = { last_synced => $first, items => 203, source => 'scan' };

	Plugins::SqueezeWax::Plugin::_syncTick();

	is( scalar @SYNCS, 1,
		"a 'scan' marker from the PREVIOUS scan's window does not skip this one" );
}

# A scan can notify two or three times (observed 2026-09-22: three in 2.7 s). A
# duplicate must not move the window's lower bound, or the marker written
# during the scan - before the first notification - falls outside it.
{
	reset_state();
	$PREFS{discogsToken} = 'a-token';

	my ( $init, $first ) = open_window();

	# The marker was written during the scan, before the first notification.
	$MARKER = { last_synced => $first - 40, items => 203, source => 'scan' };

	$NOW = $first + 2;
	Plugins::SqueezeWax::Plugin::_rescanDone();    # the duplicate

	Plugins::SqueezeWax::Plugin::_syncTick();

	is( scalar @SYNCS, 0,
		'a duplicate rescan-done moves only the upper bound, so the skip still holds' );
}

# Order: after the token check, before the rejection pause.
{
	reset_state();
	delete $PREFS{discogsToken};

	my ( $init, $done ) = open_window();
	$MARKER = { last_synced => $done, items => 203, source => 'scan' };

	Plugins::SqueezeWax::Plugin::_syncTick();

	ok( ( grep { /no Discogs token/ } @LOG ) && !( grep { /scan already synced/ } @LOG ),
		'with no token the tick stops at the token check, before the marker is consulted' );
}

{
	reset_state();
	$PREFS{discogsToken} = 'a-token';
	$REJECTED = 1;

	my ( $init, $done ) = open_window();
	$MARKER = { last_synced => $done, items => 203, source => 'scan' };

	Plugins::SqueezeWax::Plugin::_syncTick();

	is( scalar @SKIPS, 0,
		'a healthy scan-time sync skips before the rejection pause is consulted' );
	is( scalar @SYNCS, 0, '  ...and starts no sync' );
}

# ---------------------------------------------------------------------------
# The master derive trigger (build-order step 8c, decisions §15.22)
# ---------------------------------------------------------------------------
#
# Two sites, and BOTH matter. The plan names only _syncDone; the skip above is
# the deviation, and it is the site that actually fires on this project's
# reference server. Everything else that can end a tick or a sync must NOT arm
# the job: it is triggered by a completed sync and by nothing else (§15.15 part
# 1 - no interval, no startup run).

diag('§15.22: the derive job is armed by a completed sync, and by nothing else');

{
	reset_state();

	Plugins::SqueezeWax::Plugin::_syncDone( { ok => 1, items => 203, requests => 4 } );

	is( scalar @ARMED, 1, 'a successful fallback sync arms the derive job' );
}

for my $error (qw(unauthorized already_running refused no_response count_mismatch)) {
	reset_state();

	Plugins::SqueezeWax::Plugin::_syncDone( { ok => 0, error => $error } );

	is( scalar @ARMED, 0, "a sync that failed with '$error' does not arm it" );
}

{
	reset_state();
	delete $PREFS{discogsToken};

	open_window();
	Plugins::SqueezeWax::Plugin::_syncTick();

	is( scalar @ARMED, 0, 'a tick with no token arms nothing - there is no collection to badge from' );
}

{
	reset_state();
	$PREFS{discogsToken} = 'a-token';
	$REJECTED = 1;

	open_window();
	$MARKER = undef;
	Plugins::SqueezeWax::Plugin::_syncTick();

	is( scalar @SYNCS, 0, 'a rejected token pauses the fallback sync' );
	is( scalar @ARMED, 0, '  ...and arms nothing either: no sync completed' );
}

{
	reset_state();
	$PREFS{discogsToken} = 'a-token';
	$SCANNING = 1;

	open_window();
	$MARKER = undef;
	Plugins::SqueezeWax::Plugin::_syncTick();

	is( scalar @SYNCS, 0, 'a tick during a scan defers the sync' );
	is( scalar @ARMED, 0, '  ...and arms nothing: the job would be refused its write anyway' );
}

{
	reset_state();

	# The subscription and the debounce arm a sync tick, never the derive job.
	# If this ever fails, something has given the job a schedule of its own.
	Plugins::SqueezeWax::Plugin::_initSync();
	Plugins::SqueezeWax::Plugin::_rescanDone();

	is( scalar @ARMED, 0,
		'initPlugin\'s subscription and the debounce arm no derive run - there is no startup run' );
}

# ---------------------------------------------------------------------------
# The logic version (decisions §15.23, §15.24)
# ---------------------------------------------------------------------------

diag('§15.24: a change to the identification rule can say "re-decide"');

# The real Tags.pm, not a stub: the constant under test is its value, and the
# whole mechanism is a comparison against it.
require Plugins::SqueezeWax::Tags;

my $LOGIC = Plugins::SqueezeWax::Tags::LOGIC_VERSION();

cmp_ok( $LOGIC, '>=', 2,
	"Tags::LOGIC_VERSION is $LOGIC - at least 2, since step 8c's cross-track rule" );

# --- absent, and no rows: a fresh install ----------------------------------
{
	reset_state();
	$HAS_ROWS = 0;

	Plugins::SqueezeWax::Plugin::_checkLogicVersion();

	is( scalar @INVALIDATIONS, 0,
		'a fresh install invalidates nothing - there is nothing to re-decide' );
	is( $META{logic_version}, $LOGIC, '  ...and records the current version' );
	is( scalar @LOG, 0, '  ...and logs nothing: no work happened' );
}

# --- absent, with rows: written before the marker existed, so version 1 -----
{
	reset_state();
	$HAS_ROWS = 1;

	Plugins::SqueezeWax::Plugin::_checkLogicVersion();

	is( scalar @INVALIDATIONS, 1,
		'an absent marker over existing rows invalidates: they were decided under rule 1' );
	is( $META{logic_version}, $LOGIC, '  ...and records the current version' );
	is( scalar @METAWRITES, 1, '  ...once' );
	like( "@LOG", qr/1 -> $LOGIC/, '  ...and the line names both versions' );
	like( "@LOG", qr/\b503\b/, '  ...and the row count invalidateStrict returned' );
}

# --- stored and older ------------------------------------------------------
{
	reset_state();
	local $main::INVALIDATE_RETURN = 0;
	$META{logic_version} = $LOGIC - 1;

	Plugins::SqueezeWax::Plugin::_checkLogicVersion();

	is( scalar @INVALIDATIONS, 1, 'a stored version older than the code invalidates' );
	is( $META{logic_version}, $LOGIC, '  ...and records the new one' );

	# 0 rows is a real answer, not a refusal: an invalidation that touched
	# nothing still happened, and the version must be recorded or it repeats at
	# every start forever.
	like( "@LOG", qr/0 rows invalidated/, '  ...even when it touched no rows' );
}

# --- stored and equal: the common case, and it must do nothing at all -------
{
	reset_state();
	$META{logic_version} = $LOGIC;

	Plugins::SqueezeWax::Plugin::_checkLogicVersion();

	is( scalar @INVALIDATIONS, 0, 'a matching stored version invalidates nothing' );
	is( scalar @METAWRITES, 0, '  ...and writes nothing' );
	is( scalar @LOG, 0, '  ...and logs nothing - this is every normal start' );
}

# --- stored and NEWER: a downgrade --------------------------------------
{
	reset_state();
	$META{logic_version} = $LOGIC + 1;

	Plugins::SqueezeWax::Plugin::_checkLogicVersion();

	is( scalar @INVALIDATIONS, 0,
		'a database written by a newer SqueezeWax is left alone' );
	is( $META{logic_version}, $LOGIC + 1,
		'  ...and its marker is NOT overwritten with the lower number' );
	is( scalar @METAWRITES, 0, '  ...so nothing is written at all' );
}

# --- the refusal, which is the one that would be permanent ------------------
#
# invalidateStrict returns undef when _writeOk says no (Match.pm:105) - during a
# scan, or with the schema unusable. Recording the version anyway would skip the
# invalidation forever: the same silent, permanent failure §15.23 describes,
# with an extra step.
{
	reset_state();
	$META{logic_version} = 1;
	$INVALIDATE_RETURN   = undef;

	Plugins::SqueezeWax::Plugin::_checkLogicVersion();

	is( scalar @INVALIDATIONS, 1, 'a refused invalidation was still attempted' );
	is( $META{logic_version}, 1, '  ...and the stored version is left UNCHANGED' );
	is( scalar @METAWRITES, 0, '  ...with nothing written' );
	like( "@LOG", qr/retry/, '  ...and the line says it will be tried again' );

	# ...and the next start, with the refusal gone, does the work.
	@LOG           = ();
	@INVALIDATIONS = ();
	$INVALIDATE_RETURN = 12;

	Plugins::SqueezeWax::Plugin::_checkLogicVersion();

	is( scalar @INVALIDATIONS, 1, 'the next start invalidates, because nothing was recorded' );
	is( $META{logic_version}, $LOGIC, '  ...and records the version this time' );
}

# --- the schema is not usable: unknowable, not "fresh install" --------------
{
	reset_state();
	$READY    = 0;
	$HAS_ROWS = 0;

	Plugins::SqueezeWax::Plugin::_checkLogicVersion();

	is( scalar @INVALIDATIONS, 0, 'an unusable schema invalidates nothing' );
	is( scalar @METAWRITES, 0,
		'  ...and records nothing: a marker written now would claim a re-examination '
		. 'that never happened' );
}

# --- and it runs from initPlugin, after Schema->init ------------------------
#
# The check is worth nothing if it is never called. initPlugin is the only
# caller, and a suite that drove _checkLogicVersion alone would stay green if
# the call were deleted.
{
	reset_state();
	$META{logic_version} = 1;

	Plugins::SqueezeWax::Plugin->initPlugin();

	is( scalar @INVALIDATIONS, 1, 'initPlugin runs the logic-version check' );
	is( $META{logic_version}, $LOGIC, '  ...and the new version is recorded' );
	is( scalar @TIMERS, 0, '  ...and it still arms no timer (§15.15 part 1)' );

	# The ownership menu is registered from the same entry point, and from
	# nowhere else (build-order step 9). Not under main::WEBUI: the album and
	# track menus are served to players and the CLI as well as to the skins.
	is( scalar @MENU_INIT, 1, '  ...and it registers the ownership menu' );
	is( scalar @VIEW_INIT, 1, '  ...and the "Records I own" view' );
}

done_testing();
