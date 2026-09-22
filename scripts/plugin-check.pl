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

our @TIMERS;      # every setTimer call
our @KILLS;       # every killTimers call
our @SUBSCRIBED;  # every Slim::Control::Request::subscribe call
our @SYNCS;       # every Async->sync call
our %PREFS;
our %MIGRATIONS;  # version => coderef, as recorded by the prefs stub
our $SCANNING = 0;

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
	*{'main::INFOLOG'}   = sub () { 0 };
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
	sub set { $PREFS{ $_[1] } = $_[2]; return 1 }
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
	sub setChange   { 1 }
	sub remove      { delete $PREFS{ $_[1] }; delete $PREFS{ '_ts_' . $_[1] }; return 1 }
}

{
	package Test::StubLogger;
	sub new      { bless {}, shift }
	sub error    { } sub warn { } sub info { } sub debug { }
	sub is_info  { 0 } sub is_debug { 0 }
}

our %VALIDATED;

{
	package Plugins::SqueezeWax::Schema;
	sub init { 1 }
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

sub reset_state {
	@TIMERS = ();
	@KILLS  = ();
	@SYNCS  = ();
	@SUBSCRIBED = ();
	$SCANNING = 0;
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
		discogsLastSynced       => 1790085746,
	);

	$MIGRATIONS{2}->( Test::StubPrefs->new );

	ok( !exists $PREFS{discogsSyncInterval},
		'  ...and it removes discogsSyncInterval from an existing prefs file' );
	ok( !exists $PREFS{_ts_discogsSyncInterval},
		'  ...along with its _ts_ twin (Slim/Utils/Prefs/Base.pm:242-258)' );
	is( $PREFS{discogsToken},      'keep-me',   '  ...and touches nothing else' );
	is( $PREFS{discogsLastSynced}, 1790085746,  '  ...including the last-synced time' );
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

done_testing();
