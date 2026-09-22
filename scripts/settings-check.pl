#!/usr/bin/env perl
#
# Offline exercise of Plugins::SqueezeWax::Settings' ACTION DISPATCH.
#
# Why this file exists: 0.0.0.3 shipped with two dead buttons. Every submit
# from a settings page carries a HIDDEN saveSettings=1
# (refs/slimserver/HTML/EN/settings/footer.html:39, beside the visible Save
# button at :38), and handler() tested saveSettings SECOND in its elsif chain,
# so it swallowed syncNow and testToken, which sat behind it. The page
# re-rendered having saved, the action never ran, and nothing was logged -
# because the action's own code was never reached. detectTagNames was tested
# first and so always worked, which is why nobody noticed.
#
# One assertion - that a params hash carrying BOTH saveSettings and syncNow
# reaches _syncNow - would have caught it. That assertion is below, with its
# siblings for the other three buttons.
#
# It drives the REAL handler(), not an extracted dispatcher. Extracting the
# chain into a pure sub and testing that would leave the shipped dispatch
# exactly as untested as it was when the bug shipped, which is the one
# outcome this file is for. Nothing in Settings.pm is refactored to make it
# testable; the stubs go at the module's real boundaries instead.
#
# Which action ran is observed at those boundaries, never by overriding the
# action subs themselves:
#   syncNow        -> Plugins::SqueezeWax::API::Async->sync
#   testToken      -> Slim::Networking::SimpleAsyncHTTP->new(...)->get
#   detectTagNames -> Library->sample_albums, then Scheduler::add_task
#   saveSettings   -> the discogsTagNames pref is written (and the strict
#                     cache invalidated, but only when the SET changed - §3b)
#
# What it CANNOT prove: that the browser sends what footer.html says it
# sends. The hidden field is read out of refs/ below and asserted, so a core
# change to that template fails here rather than silently in the field.
#
# Usage: scripts/settings-check.pl

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

our %CALLS;
our %PREFS;

# ---------------------------------------------------------------------------
# Stubs, at the module's real boundaries
# ---------------------------------------------------------------------------
#
# Each cites what it stands in for. Settings.pm is loaded only under
# main::WEBUI in the real server, so everything here is a web-side dependency.
BEGIN {
	# Slim/Web/Settings.pm - the base class. Its handler() is the generic
	# prefs path (Slim/Web/Settings.pm:135-176) that saves pref_* scalars and
	# renders. Stubbed to a marker: this suite is about which branch of OUR
	# handler runs, not about core's rendering.
	$INC{'Slim/Web/Settings.pm'} = 1;
	# Slim/Web/HTTP/CSRF.pm:29-68 - protectName/protectURI register a page for
	# CSRF checking and return the name/URI unchanged.
	$INC{'Slim/Web/HTTP/CSRF.pm'}           = 1;
	$INC{'Slim/Utils/Log.pm'}               = 1;
	$INC{'Slim/Utils/Prefs.pm'}             = 1;
	$INC{'Slim/Utils/Strings.pm'}           = 1;
	$INC{'Slim/Utils/DateTime.pm'}          = 1;
	# Slim/Utils/Scheduler.pm:70,109 - add_task/remove_task.
	$INC{'Slim/Utils/Scheduler.pm'}         = 1;
	# Slim/Music/Import.pm:730-754 - stillScanning.
	$INC{'Slim/Music/Import.pm'}            = 1;
	$INC{'Slim/Schema.pm'}                  = 1;
	$INC{'Slim/Music/Info.pm'}              = 1;
	$INC{'Slim/Formats.pm'}                 = 1;
	# Slim/Networking/SimpleAsyncHTTP.pm - the async transport _testToken uses.
	$INC{'Slim/Networking/SimpleAsyncHTTP.pm'} = 1;
	# _testToken requires API.pm, whose only Slim dependency is
	# _pluginVersion's dataForPlugin (Slim/Utils/PluginManager.pm:478-487).
	# Stubbed the same way scripts/api-check.pl:58 stubs it, so API.pm itself
	# loads and runs for real - buildRequest is what puts the token in the
	# header, and a suite that stubbed API.pm would stop testing that.
	$INC{'Slim/Utils/PluginManager.pm'} = 1;

	no strict 'refs';

	*{'Slim::Web::Settings::handler'} = sub {
		$CALLS{super_handler}++;
		return 'RENDERED';
	};

	*{'Slim::Web::HTTP::CSRF::protectName'} = sub { $_[1] };
	*{'Slim::Web::HTTP::CSRF::protectURI'}  = sub { $_[1] };

	*{'Slim::Utils::Log::logger'}   = sub { Test::StubLogger->new };
	*{'Slim::Utils::Log::logError'} = sub { };
	*{'Slim::Utils::Log::import'}   = sub {
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

	# The string token is returned unchanged, so an assertion can name the
	# string a branch chose rather than its English text.
	*{'Slim::Utils::Strings::string'} = sub { $_[0] };
	*{'Slim::Utils::Strings::import'} = sub {
		my $caller = caller;
		no strict 'refs';
		*{ $caller . '::string' } = \&Slim::Utils::Strings::string;
	};

	*{'Slim::Utils::PluginManager::dataForPlugin'} = sub { { version => '0.0.0-test' } };

	*{'Slim::Utils::DateTime::shortDateF'} = sub { 'DATE' };
	*{'Slim::Utils::DateTime::timeF'}      = sub { 'TIME' };

	*{'Slim::Utils::Scheduler::add_task'}    = sub { $CALLS{add_task}++ };
	*{'Slim::Utils::Scheduler::remove_task'} = sub { $CALLS{remove_task}++ };

	*{'Slim::Music::Import::stillScanning'} = sub { $main::SCANNING };

	*{'main::SCANNER'}   = sub () { 0 };
	*{'main::INFOLOG'}   = sub () { 0 };
	*{'main::DEBUGLOG'}  = sub () { 0 };
	*{'main::ISWINDOWS'} = sub () { 0 };
	*{'main::WEBUI'}     = sub () { 1 };
}

our $SCANNING = 0;

{
	package Test::StubPrefs;
	sub new { bless {}, shift }
	sub get { return $PREFS{ $_[1] } }
	sub set { $PREFS{ $_[1] } = $_[2]; $CALLS{"pref_set_$_[1]"}++; return 1 }

	# init/migrate/setValidate/setChange run at file scope in Tags.pm and
	# Plugin.pm. They establish defaults and validators, which this suite
	# neither exercises nor needs; init seeds the store so get() behaves.
	sub init {
		my ( $self, $defaults ) = @_;
		for my $k ( keys %{ $defaults || {} } ) {
			$PREFS{$k} = $defaults->{$k} unless exists $PREFS{$k};
		}
		return 1;
	}
	sub migrate     { 1 }
	sub setValidate { 1 }
	sub setChange   { 1 }
}

{
	package Test::StubLogger;
	sub new      { bless {}, shift }
	sub error    { }
	sub warn     { }
	sub info     { }
	sub debug    { }
	sub is_info  { 0 }
	sub is_debug { 0 }
}

# The two transports, stubbed at their boundary.
{
	package Slim::Networking::SimpleAsyncHTTP;
	sub new { my ( $c, $ok, $err, $opt ) = @_; return bless { ok => $ok }, $c }
	sub get { $CALLS{http_get}++; return 1 }
}

my $incdir;

BEGIN {
	$incdir = tempdir( CLEANUP => 1 );
	mkdir "$incdir/Plugins";
	symlink "$Bin/../SqueezeWax", "$incdir/Plugins/SqueezeWax"
		or die "could not link the plugin into $incdir: $!\n";
	unshift @INC, $incdir;
}

# Async is required lazily inside _syncNow. Pre-registering it in %INC makes
# that require a no-op so the real sync is never reached: this suite must not
# depend on a network, and the sync has its own suite.
BEGIN {
	$INC{'Plugins/SqueezeWax/API/Async.pm'} = 1;

	no strict 'refs';
	*{'Plugins::SqueezeWax::API::Async::sync'} = sub {
		my ( $class, $token, $cb ) = @_;
		$CALLS{async_sync}++;
		$CALLS{async_sync_token} = $token;
		$cb->( { ok => 1, items => 203, requests => 4 } );
		return 1;
	};
	*{'Plugins::SqueezeWax::API::Async::status'} = sub {
		return { running => 0, lastSynced => 0, lastItems => undef, lastError => '' };
	};
}

require Plugins::SqueezeWax::Settings;

# isReady/lastError are Schema's readiness flag. Overridden rather than
# migrated: this suite opens no database at all.
{
	no warnings 'once', 'redefine';
	*Plugins::SqueezeWax::Schema::isReady   = sub { $main::DB_READY };
	*Plugins::SqueezeWax::Schema::lastError = sub { 'db broken' };
	# detectTagNames' only database read; the detection worker itself is
	# Tags.pm's business and has its own suite.
	*Plugins::SqueezeWax::Library::sample_albums = sub {
		$CALLS{sample_albums}++;
		return [];
	};
	*Plugins::SqueezeWax::Match::invalidateStrict = sub {
		$CALLS{invalidate}++;
		return 0;
	};
	*Plugins::SqueezeWax::Tags::tagNames = sub { [] };
}

our $DB_READY = 1;

# ---------------------------------------------------------------------------
# Driving handler()
# ---------------------------------------------------------------------------

# Every submit carries the hidden saveSettings=1. That is the whole point:
# callers below add an action on top of it, exactly as the browser does.
sub submit {
	my (%extra) = @_;

	%CALLS = ();

	my $params = { saveSettings => 1, %extra };
	my @cbArgs;

	my $callback = sub { $CALLS{callback}++; @cbArgs = @_; return 1 };

	my $rc = Plugins::SqueezeWax::Settings->handler(
		undef, $params, $callback, 'ARG1' );

	return ( $params, $rc );
}

# ---------------------------------------------------------------------------
# The dispatch: which action does a submit actually run
# ---------------------------------------------------------------------------

diag('dispatch: the hidden saveSettings must never swallow a named action');

{
	$PREFS{discogsToken} = 'a-token';
	my ($params) = submit( syncNow => 1 );

	ok( $CALLS{async_sync}, 'saveSettings + syncNow reaches _syncNow' );
	is( $CALLS{async_sync_token}, 'a-token', '  ...with the stored token' );
	ok( !$CALLS{invalidate}, '  ...and does NOT fall through to the tag-name save' );
	ok( $CALLS{callback},    '  ...and renders through the deferred callback' );
}

{
	$PREFS{discogsToken} = 'a-token';
	my ($params) = submit( testToken => 1 );

	ok( $CALLS{http_get}, 'saveSettings + testToken reaches _testToken' );
	ok( !$CALLS{async_sync}, '  ...and not the sync' );
	ok( !$CALLS{invalidate}, '  ...and not the tag-name save' );
}

{
	my ($params) = submit( detectTagNames => 1 );

	ok( $CALLS{sample_albums}, 'saveSettings + detectTagNames reaches _startDetection' );
	ok( $CALLS{add_task},      '  ...and schedules the worker' );
	ok( !$CALLS{async_sync},   '  ...and not the sync' );
}

{
	my ($params) = submit();

	ok( $CALLS{pref_set_discogsTagNames},
		'saveSettings alone reaches _saveTagNames and writes the pref' );
	ok( !$CALLS{async_sync},   '  ...and starts no sync' );
	ok( !$CALLS{http_get},     '  ...and tests no token' );
	ok( !$CALLS{sample_albums}, '  ...and starts no detection' );
	ok( $CALLS{super_handler}, '  ...and falls through to the base handler' );
}

# The strict cache is invalidated only when the SET of names changed (§3b) -
# a save that changes nothing must not cost a cold pass over every file.
{
	$PREFS{discogsTagNames} = [];

	my ($params) = submit( pref_discogsTagNames0 => 'DISCOGS_RELEASE_ID' );
	ok( $CALLS{invalidate}, 'a save that CHANGES the tag-name set invalidates' );

	my ($again) = submit( pref_discogsTagNames0 => 'DISCOGS_RELEASE_ID' );
	ok( $CALLS{pref_set_discogsTagNames}, 'saving the same set still writes the pref' );
	ok( !$CALLS{invalidate}, '  ...but does NOT invalidate again' );
}

# Two actions at once cannot happen from the page - a form submits one button -
# but the chain's order is still a fact worth pinning: detectTagNames first,
# then syncNow, then testToken, then saveSettings.
{
	# A detection is still running from the test above, so _startDetection's
	# staleness guard (Settings.pm:400-403) returns early rather than starting
	# a second one. That is the branch being taken: syncNow must still not run.
	my ($params) = submit( detectTagNames => 1, syncNow => 1 );

	ok( !$CALLS{async_sync}, 'detectTagNames wins over syncNow' );
	ok( !$CALLS{sample_albums},
		'  ...and a second detection is refused while one is running' );
}

{
	my ($params) = submit( syncNow => 1, testToken => 1 );

	ok( $CALLS{async_sync}, 'syncNow wins over testToken' );
	ok( !$CALLS{http_get},  '  ...which does not also run' );
}

# ---------------------------------------------------------------------------
# The refusals
# ---------------------------------------------------------------------------

diag('refusals: every action refuses while a scan holds the write lock');

{
	local $main::SCANNING = 1;

	my ($params) = submit( syncNow => 1 );
	is( $params->{warning}, 'PLUGIN_SQUEEZEWAX_BUSY_SCANNING',
		'syncNow refuses while scanning' );
	ok( !$CALLS{async_sync}, '  ...and starts no sync' );
}

{
	local $main::SCANNING = 1;

	my ($params) = submit( testToken => 1 );
	is( $params->{warning}, 'PLUGIN_SQUEEZEWAX_BUSY_SCANNING',
		'testToken refuses while scanning' );
	ok( !$CALLS{http_get}, '  ...and issues no request' );
}

{
	local $main::SCANNING = 1;

	my ($params) = submit( detectTagNames => 1 );
	is( $params->{warning}, 'PLUGIN_SQUEEZEWAX_BUSY_SCANNING',
		'detectTagNames refuses while scanning' );
	ok( !$CALLS{sample_albums}, '  ...and reads no albums' );
}

{
	local $main::SCANNING = 1;

	my ($params) = submit();
	is( $params->{warning}, 'PLUGIN_SQUEEZEWAX_BUSY_SCANNING',
		'a plain save refuses while scanning' );
	ok( !$CALLS{invalidate}, '  ...and invalidates nothing' );
}

{
	local $main::DB_READY = 0;

	my ($params) = submit();
	like( $params->{warning}, qr/^PLUGIN_SQUEEZEWAX_DB_UNUSABLE/,
		'a plain save refuses when squeezewax.db is unusable' );
	ok( !$CALLS{invalidate}, '  ...and invalidates nothing' );
}

{
	local $main::DB_READY = 0;

	my ($params) = submit( testToken => 1 );
	like( $params->{warning}, qr/^PLUGIN_SQUEEZEWAX_DB_UNUSABLE/,
		'testToken refuses when squeezewax.db is unusable' );
	ok( !$CALLS{http_get}, '  ...and issues no request' );
}

diag('refusals: the sync needs a token');

{
	delete $PREFS{discogsToken};

	my ($params) = submit( syncNow => 1 );
	is( $params->{syncResult}, 'PLUGIN_SQUEEZEWAX_SYNC_NO_TOKEN',
		'syncNow with no token says so rather than starting one' );
	ok( !$CALLS{async_sync}, '  ...and starts no sync' );
	ok( $CALLS{callback},    '  ...and still renders the page' );
}

{
	$PREFS{discogsToken} = '';

	my ($params) = submit( syncNow => 1 );
	is( $params->{syncResult}, 'PLUGIN_SQUEEZEWAX_SYNC_NO_TOKEN',
		'an empty token is no token' );
	ok( !$CALLS{async_sync}, '  ...and starts no sync' );
}

{
	delete $PREFS{discogsToken};

	my ($params) = submit( testToken => 1 );
	is( $params->{tokenTestResult}, 'PLUGIN_SQUEEZEWAX_TOKEN_TEST_MISSING',
		'testToken with no token says so rather than issuing a request' );
	ok( !$CALLS{http_get}, '  ...and issues no request' );
}

# The unsaved field beats the stored pref - the point of a Test button is to
# check before committing to Save.
{
	$PREFS{discogsToken} = 'stored';

	%CALLS = ();
	my $params = { saveSettings => 1, testToken => 1, pref_discogsToken => 'typed' };
	Plugins::SqueezeWax::Settings->handler( undef, $params, sub { 1 }, 'ARG1' );

	ok( $CALLS{http_get}, 'testToken uses the field, not the stored pref' );
}

# ---------------------------------------------------------------------------
# The premise this suite rests on
# ---------------------------------------------------------------------------

diag('the hidden field, read out of refs/ rather than assumed');

{
	my $footer = "$Bin/../refs/slimserver/HTML/EN/settings/footer.html";
	open my $fh, '<', $footer or die "could not read $footer: $!\n";
	my $html = do { local $/; <$fh> };
	close $fh;

	like( $html, qr/<input\s+type="hidden"\s+name="saveSettings"/,
		'settings/footer.html still ships a HIDDEN saveSettings field' );
}

done_testing();
