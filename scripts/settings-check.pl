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
our @EVENTS;   # ordered, because ORDER is what broke
our @RESPONSES; # canned HTTP responses, consumed in order by the transport
our @REQUESTS;  # every request the transport was asked to issue

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
	# Models two real behaviours that a naive stub hides, and whose interaction
	# shipped a regression on 2026-09-24:
	#
	#   1. Slim/Utils/Prefs/Base.pm:94-97 suppresses a scalar set that does not
	#      change the value - onchange included.
	#   2. Plugin.pm registers setChange on discogsToken to clear the rejection
	#      pause (§15.15 parts 2 and 3). Plugin.pm is not loaded here, so the
	#      hook is mirrored rather than imported; if that hook moves, this stub
	#      is a lie and the comment says where to look.
	sub set {
		my ( $self, $pref, $new ) = @_;

		my $old = $PREFS{$pref};

		return 1 if !ref $new
			&& defined $new
			&& defined $old
			&& $new eq $old;

		$PREFS{$pref} = $new;
		$CALLS{"pref_set_$pref"}++;
		push @EVENTS, "set:$pref";

		if ( $pref eq 'discogsToken' ) {
			Plugins::SqueezeWax::API::Async->clearTokenRejected;
		}

		return 1;
	}

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

# The transport, modelled on the real routing rather than counted.
#
# Until 2026-09-24 this counted the request and returned WITHOUT CALLING EITHER
# CALLBACK, so _tokenTested, _tokenTestFailureString and the status fix inside
# _testToken's own $done closure were unreachable: the suite proved a request
# was issued and nothing about what came back. That fix shipped in 0.0.0.8 with
# no evidence behind it anywhere (stub audit 2026-09-24, entry 1.1).
#
# The routing is the same one sync-check.pl models, for the same reason:
# refs/slimserver/Slim/Networking/Async/HTTP.pm:434-436 sends every status that
# is not 2xx or 3xx to _http_error, which reaches SimpleAsyncHTTP's onError
# (:76-101). onError sets neither code nor content on the object and passes the
# HTTP::Response as its THIRD argument (:96); only onBody sets them (:112-114)
# and then calls the success callback.
{
	package Slim::Networking::SimpleAsyncHTTP;

	sub new {
		my ( $class, $cb, $ecb, $args ) = @_;

		return bless { cb => $cb, ecb => $ecb, args => $args }, $class;
	}

	sub get {
		my ( $self, $url, @headers ) = @_;

		$CALLS{http_get}++;
		push @REQUESTS, { url => $url, headers => \@headers };

		my $canned = shift @RESPONSES;

		# No canned response queued: behave as the old stub did and simply
		# return, so a test that only cares that a request was issued still
		# works without inventing an outcome for it.
		return 1 unless $canned;

		# A connection that never produced a status at all - no response
		# object either. The only thing that should classify as no_response.
		if ( !defined $canned->{code} ) {
			$self->{ecb}->( $self, 'connection failed', undef );

			return 1;
		}

		my $response = Test::StubResponse->new($canned);

		if ( $canned->{code} !~ /^[23]\d\d$/ ) {
			$self->{ecb}->( $self, "HTTP $canned->{code}", $response );

			return 1;
		}

		$self->{code}    = $canned->{code};
		$self->{content} = $canned->{content};

		$self->{cb}->($self);

		return 1;
	}

	sub code    { $_[0]->{code} }
	sub content { $_[0]->{content} }
	sub headers { $_[0]->{headers} }
}

# What onError hands over as its third argument.
{
	package Test::StubResponse;

	sub new {
		my ( $class, $canned ) = @_;

		return bless {
			code    => $canned->{code},
			content => $canned->{content},
		}, $class;
	}

	sub code    { $_[0]->{code} }
	sub content { $_[0]->{content} }
	sub headers { undef }
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
		push @EVENTS, 'sync';
		$cb->( { ok => 1, items => 203, requests => 4 } );
		return 1;
	};
	*{'Plugins::SqueezeWax::API::Async::status'} = sub {
		return { running => 0, lastSynced => 0, lastItems => undef, lastError => '' };
	};
	*{'Plugins::SqueezeWax::API::Async::clearTokenRejected'} = sub {
		$CALLS{clear_rejected}++;
		push @EVENTS, 'clear_pause';
		return;
	};
	*{'Plugins::SqueezeWax::API::Async::tokenRejected'} = sub { 0 };
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

	%CALLS     = ();
	@EVENTS    = ();
	@REQUESTS  = ();

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

# ---------------------------------------------------------------------------
# Button feedback (2026-09-22): what of it is testable server-side
# ---------------------------------------------------------------------------
#
# The disabling itself is browser behaviour and is not tested here. What IS
# testable, and what actually breaks if someone edits the template: that the
# buttons the script wires up are exactly the ones handler() dispatches on,
# that each of those names still reaches its action when it arrives as a
# HIDDEN field (which is how it arrives once the button is disabled), and that
# every running string the template names exists in strings.txt.

diag('button feedback: the template and the dispatcher must agree');

my $TEMPLATE = "$Bin/../SqueezeWax/HTML/EN/plugins/SqueezeWax/settings.html";
my $STRINGS  = "$Bin/../SqueezeWax/strings.txt";

my $tpl = do {
	open my $fh, '<', $TEMPLATE or die "could not read $TEMPLATE: $!\n";
	local $/;
	<$fh>;
};

my $strings = do {
	open my $fh, '<', $STRINGS or die "could not read $STRINGS: $!\n";
	local $/;
	<$fh>;
};

# Every input carrying the swxAction class, with the running string it names.
my %wired;

while ( $tpl =~ /<input\s+name="([^"]+)"[^>]*?class="[^"]*\bswxAction\b[^"]*"(.*?)\/>/gs ) {
	my ( $name, $rest ) = ( $1, $2 );

	my ($running) = $rest =~ /data-swx-running="\[%\s*"([^"]+)"/;

	$wired{$name} = $running;
}

is_deeply( [ sort keys %wired ], [ sort qw(detectTagNames syncNow testToken) ],
	'the template wires exactly the three action buttons handler() dispatches on' );

for my $name ( sort keys %wired ) {
	ok( defined $wired{$name}, "$name names a running string" );

	like( $strings, qr/^\Q$wired{$name}\E\n\tEN\t\S/m,
		"  ...$wired{$name} exists in strings.txt with EN text" )
		if defined $wired{$name};
}

# The hidden field carries the SAME name the button had, so the server cannot
# tell the two apart - which is the point. Driven from the parsed template, so
# renaming a button without renaming its param fails here.
{
	$PREFS{discogsToken} = 'a-token';

	%CALLS = ();
	Plugins::SqueezeWax::Settings->handler( undef,
		{ saveSettings => 1, syncNow => 'Sync collection now' }, sub { 1 }, 'ARG1' );
	ok( $CALLS{async_sync},
		'syncNow arriving as a hidden field (button value, not 1) still reaches _syncNow' );

	%CALLS = ();
	Plugins::SqueezeWax::Settings->handler( undef,
		{ saveSettings => 1, testToken => 'Test token' }, sub { 1 }, 'ARG1' );
	ok( $CALLS{http_get}, 'testToken likewise' );
}

# The ordering the hidden field depends on: the name is copied BEFORE anything
# is disabled. Reversed, every action would fall through to a plain save.
{
	my ($script) = $tpl =~ /<script type="text\/javascript">(.*?)<\/script>/s;

	ok( $script, 'the template carries the feedback script' );

	if ($script) {
		my $append  = index( $script, 'form.appendChild(hidden)' );
		my $disable = index( $script, 'disabled = true' );
		my $defer   = index( $script, 'setTimeout(' );

		ok( $append >= 0,  '  ...which copies the clicked name into a hidden field' );
		ok( $disable >= 0, '  ...and disables the buttons' );
		ok( $append >= 0 && $disable >= 0 && $append < $disable,
			'  ...copying BEFORE disabling, or the name never reaches the server' );

		# The regression 0.0.0.5 shipped. Disabling a submit button inside its
		# own click handler does not just drop its name from the form data
		# set - it CANCELS the submission. The buttons greyed out, relabelled,
		# and nothing was ever sent. The disable has to be deferred past the
		# current task, and the ordering assertion above cannot see the
		# difference, because copying still came first.
		ok( $defer >= 0, '  ...and defers the disable with setTimeout' );
		ok( $defer >= 0 && $disable >= 0 && $defer < $disable,
			'  ...with the disable INSIDE the deferral, or the form never submits' );
	}
}

# ---------------------------------------------------------------------------
# One meaning for the buttons (§15.15 part 3)
# ---------------------------------------------------------------------------
#
# Both buttons act on the token ON THE PAGE. Sync now read the STORED pref
# until 2026-09-22 while the shared form saved the field afterwards, so it
# synced with the old token and stored the new one - observed on the reference
# server, where pasting a wrong token and pressing Sync now produced a
# SUCCESSFUL sync against the previous token.

diag('§15.15 part 3: both buttons act on the token on the page');

{
	$PREFS{discogsToken} = 'stored-old';

	%CALLS = ();
	my $params = { saveSettings => 1, syncNow => 1, pref_discogsToken => 'typed-new' };
	Plugins::SqueezeWax::Settings->handler( undef, $params, sub { 1 }, 'ARG1' );

	is( $CALLS{async_sync_token}, 'typed-new',
		'Sync now uses the token in the FIELD, not the stored one' );
}

{
	$PREFS{discogsToken} = 'stored-old';

	%CALLS = ();
	my $params = { saveSettings => 1, syncNow => 1 };
	Plugins::SqueezeWax::Settings->handler( undef, $params, sub { 1 }, 'ARG1' );

	is( $CALLS{async_sync_token}, 'stored-old',
		'  ...falling back to the stored token when the field is absent' );
}

{
	$PREFS{discogsToken} = 'stored-old';

	%CALLS = ();
	my $params = { saveSettings => 1, syncNow => 1, pref_discogsToken => '' };
	Plugins::SqueezeWax::Settings->handler( undef, $params, sub { 1 }, 'ARG1' );

	is( $CALLS{async_sync_token}, 'stored-old',
		'  ...and an EMPTY field is not a token, so the stored one still wins' );
}

# The two buttons now agree, which is the whole point of the ruling.
{
	$PREFS{discogsToken} = 'stored-old';

	%CALLS = ();
	Plugins::SqueezeWax::Settings->handler( undef,
		{ saveSettings => 1, testToken => 1, pref_discogsToken => 'typed-new' },
		sub { 1 }, 'ARG1' );
	my $testUsedField = $CALLS{http_get} ? 1 : 0;

	%CALLS = ();
	Plugins::SqueezeWax::Settings->handler( undef,
		{ saveSettings => 1, syncNow => 1, pref_discogsToken => 'typed-new' },
		sub { 1 }, 'ARG1' );

	ok( $testUsedField && $CALLS{async_sync_token} eq 'typed-new',
		'Test token and Sync now now mean the same thing by "the token"' );
}

# The hint that says so has to exist, or the behaviour is right and still not
# discoverable - which is what the ruling actually complained about.
{
	my $tpl = do {
		open my $fh, '<', $TEMPLATE or die "could not read $TEMPLATE: $!\n";
		local $/;
		<$fh>;
	};

	my $strings = do {
		open my $fh, '<', $STRINGS or die "could not read $STRINGS: $!\n";
		local $/;
		<$fh>;
	};

	my $uses = () = $tpl =~ /PLUGIN_SQUEEZEWAX_ACTIONS_HINT/g;

	ok( $uses >= 2, 'the page states what the buttons act on, beside both of them' );
	like( $strings, qr/^PLUGIN_SQUEEZEWAX_ACTIONS_HINT\n\tEN\t\S/m,
		'  ...and the string exists with EN text' );
}

# ---------------------------------------------------------------------------
# The token is saved BEFORE the sync, not after (2026-09-24 regression)
# ---------------------------------------------------------------------------
#
# The shared form saves through SUPER::handler in _finishSyncNow, which runs
# from the SYNC'S OWN CALLBACK - so the save lands after the sync finishes.
# Plugin.pm's setChange on discogsToken clears the rejection pause. Together:
# a rejected sync set the pause and the save that followed wiped it, so the
# next finished scan synced anyway instead of being skipped. Observed on the
# reference server, 0.0.0.7, 2026-09-24.
#
# Neither suite could see it - settings-check stubbed Async wholesale, and
# sync-check never goes through the save path. The StubPrefs above now models
# the dispatch, so the order is testable here.

diag('a rejected pause must survive the save that follows it');

{
	$PREFS{discogsToken} = 'old-token';

	my ($params) = submit( syncNow => 1, pref_discogsToken => 'new-token' );

	my ($setAt)   = grep { $EVENTS[$_] eq 'set:discogsToken' } 0 .. $#EVENTS;
	my ($syncAt)  = grep { $EVENTS[$_] eq 'sync' }             0 .. $#EVENTS;
	my ($clearAt) = grep { $EVENTS[$_] eq 'clear_pause' }      0 .. $#EVENTS;

	ok( defined $setAt,  'a new token in the field is written to the pref' );
	ok( defined $syncAt, '  ...and a sync runs' );

	ok( defined $setAt && defined $syncAt && $setAt < $syncAt,
		'the token is saved BEFORE the sync starts' );

	ok( defined $clearAt && defined $syncAt && $clearAt < $syncAt,
		'  ...so the pause is cleared BEFORE the sync, never after it' );
}

# The same token twice must not re-fire the hook at all: Base.pm:94-97
# suppresses a scalar set that changes nothing, which is what makes the later
# SUPER::handler write harmless.
{
	$PREFS{discogsToken} = 'same-token';

	my ($params) = submit( syncNow => 1, pref_discogsToken => 'same-token' );

	ok( !( grep { $_ eq 'set:discogsToken' } @EVENTS ),
		'saving an unchanged token is suppressed' );
	ok( !$CALLS{clear_rejected},
		'  ...so the pause-clearing hook does not fire for it either' );
	ok( $CALLS{async_sync}, '  ...and the sync still runs' );
}

# ---------------------------------------------------------------------------
# The token test's RESULT path (stub audit 2026-09-24, entry 1.1)
# ---------------------------------------------------------------------------
#
# Every assertion below was unreachable until the transport above started
# calling its callbacks. _tokenTested, _tokenTestFailureString and the
# third-argument status read inside _testToken's $done closure had no test at
# all - and that status read shipped in 0.0.0.8.
#
# string() returns the token name here, so each assertion names the string the
# page would render rather than its English text.

diag('the token test result path - previously unreachable');

sub token_test {
	my (@canned) = @_;

	@RESPONSES = @canned;

	$PREFS{discogsToken} = 'a-token';

	my ($params) = submit( testToken => 1 );

	return $params->{tokenTestResult};
}

# --- the success shapes ----------------------------------------------------
# The two branches are distinguishable by string token, which is what matters
# here. The username itself is sprintf'd INTO the string, and string() returns
# the bare token, so the substitution is invisible to this suite - see the stub
# audit's entry 6 / 5.1.
is( token_test( { code => 200, content => '{"username":"deschman"}' } ),
	'PLUGIN_SQUEEZEWAX_TOKEN_TEST_OK',
	'a 200 with a username takes the OK branch' );

is( token_test( { code => 200, content => '{}' } ),
	'PLUGIN_SQUEEZEWAX_TOKEN_TEST_OK_NOUSER',
	'a 200 without a username has its own string' );

# --- THE one that matters: a rejected token --------------------------------
#
# 401 takes the ERROR path, where the object carries no code at all. Before
# 0.0.0.8 this classified as no_response and the page said "could not reach
# Discogs" for a token Discogs had actively rejected - §14.2's exact
# complaint, on the one button whose entire job is to tell them apart.
is( token_test( { code => 401, content => '{"message":"Invalid consumer token."}' } ),
	'PLUGIN_SQUEEZEWAX_TOKEN_TEST_FAIL_UNAUTHORIZED',
	'a 401 reports the token as REJECTED, not as unreachable' );

# --- the rest of the error vocabulary, all via the error path ---------------
is( token_test( { code => 404, content => '' } ),
	'PLUGIN_SQUEEZEWAX_TOKEN_TEST_FAIL_NOT_FOUND', 'a 404 has its own string' );

is( token_test( { code => 429, content => '' } ),
	'PLUGIN_SQUEEZEWAX_TOKEN_TEST_FAIL_RATE_LIMITED', 'a 429 likewise' );

is( token_test( { code => 500, content => '' } ),
	'PLUGIN_SQUEEZEWAX_TOKEN_TEST_FAIL_SERVER_ERROR', 'a 5xx likewise' );

# The code is sprintf'd in, so it is invisible here for the same reason.
is( token_test( { code => 418, content => '' } ),
	'PLUGIN_SQUEEZEWAX_TOKEN_TEST_FAIL_UNKNOWN',
	'an unmapped status falls back to the unknown string' );

# --- and the one that must STILL be no_response -----------------------------
is( token_test( { code => undef } ),
	'PLUGIN_SQUEEZEWAX_TOKEN_TEST_FAIL_NO_RESPONSE',
	'a connection that never answered is still reported as unreachable' );

# --- 200s that are not usable ----------------------------------------------
is( token_test( { code => 200, content => '' } ),
	'PLUGIN_SQUEEZEWAX_TOKEN_TEST_FAIL_EMPTY_BODY',
	'a 200 with no body is distinguishable' );

is( token_test( { code => 200, content => 'not json at all' } ),
	'PLUGIN_SQUEEZEWAX_TOKEN_TEST_FAIL_MALFORMED_JSON',
	'  ...as is a 200 whose body will not parse' );

# The request itself still carries the token being tested, not the stored one.
{
	@RESPONSES = ( { code => 200, content => '{"username":"x"}' } );
	$PREFS{discogsToken} = 'stored';

	%CALLS = (); @EVENTS = (); @REQUESTS = ();
	Plugins::SqueezeWax::Settings->handler( undef,
		{ saveSettings => 1, testToken => 1, pref_discogsToken => 'typed' },
		sub { 1 }, 'ARG1' );

	is( scalar @REQUESTS, 1, 'the test issues exactly one request' );
	ok( ( grep { /typed/ } @{ $REQUESTS[0]{headers} } ),
		'  ...carrying the token from the FIELD in its headers' );
	like( $REQUESTS[0]{url}, qr{/oauth/identity},
		'  ...to the identity endpoint (decisions §9.7)' );
}

# Every string the failure map can produce must exist, or the page renders a
# raw token at the moment the user most needs a sentence.
{
	my $strings = do {
		open my $fh, '<', $STRINGS or die "could not read $STRINGS: $!\n";
		local $/;
		<$fh>;
	};

	for my $t (qw(
		PLUGIN_SQUEEZEWAX_TOKEN_TEST_OK
		PLUGIN_SQUEEZEWAX_TOKEN_TEST_OK_NOUSER
		PLUGIN_SQUEEZEWAX_TOKEN_TEST_FAIL_UNAUTHORIZED
		PLUGIN_SQUEEZEWAX_TOKEN_TEST_FAIL_NOT_FOUND
		PLUGIN_SQUEEZEWAX_TOKEN_TEST_FAIL_RATE_LIMITED
		PLUGIN_SQUEEZEWAX_TOKEN_TEST_FAIL_SERVER_ERROR
		PLUGIN_SQUEEZEWAX_TOKEN_TEST_FAIL_NO_RESPONSE
		PLUGIN_SQUEEZEWAX_TOKEN_TEST_FAIL_EMPTY_BODY
		PLUGIN_SQUEEZEWAX_TOKEN_TEST_FAIL_MALFORMED_JSON
		PLUGIN_SQUEEZEWAX_TOKEN_TEST_FAIL_UNKNOWN
	)) {
		like( $strings, qr/^\Q$t\E\n\tEN\t\S/m, "$t exists with EN text" );
	}
}

done_testing();
