package Plugins::SqueezeWax::Details;

# Release details and master details: the two submenus build-order step 10 adds
# to an owned album's menu (decisions §15.31, plan
# plans/build-order-step-10-details.md).
#
# FETCHED ON OPEN, AND ONLY THEN. Menu.pm hands core a code reference, the shape
# of core's own "View tags" entry (refs/slimserver/Slim/Menu/TrackInfo.pm:1259-1274
# infoTagDump, :1276-1358 tagDump). Building the album menu calls nothing here;
# core calls the code reference when the user opens the entry, as
# $url->( $client, $callback, \%args, @passthrough )
# (Slim/Control/XMLBrowser.pm:471-525), and the list it is given back may arrive
# later, after Discogs has answered. menu-check.pl part 5 still proves the album
# menu itself makes no request.
#
# ONE REQUEST PER OPEN. /releases/{id} or /masters/{id}, no parameters: Discogs
# ignores curr_abbr on both and prices in the account's currency (Phase 0, T1).
# No retry - a 429 on a menu means "busy", and a user waiting on a menu is not a
# sync that can sit out a window. No cache either: LMS does not cache a list that
# holds code references (XMLBrowser.pm:342-347), so a reopened submenu fetches
# again, and Discogs' six-hour rule never comes into it.
#
# THE SAME BUDGET AS EVERYTHING ELSE. A third small server-side caller, the shape
# of Derive.pm's _fire / _handle, over API.pm's buildRequest, classifyResponse,
# rateWait and noteResponse. Not API/Async.pm's _get, which belongs to the sync
# ($run, _fail, the retry loop). When the budget is spent this does not wait: it
# says so and makes no request (§15.31 ruling 9).
#
# NOTHING IS STORED. The reply is read in memory, turned into text lines and
# dropped when the callback returns: no table, no pref, no cache (§9.5). The one
# pref read here, discogsCurrency, is written by the token test and the server
# sync, never from a details reply.
#
# THE NOTICE GOES WITH THE DATA (§9.6). Every list that shows Discogs data ends
# with "Data provided by Discogs", linked to the reply's own uri in an app that
# can open links, and followed by the address as plain text on a player, which
# cannot (§15.31 ruling 10). A list that shows no Discogs data - an error, the
# busy line, no token - carries no notice.

use strict;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

use Plugins::SqueezeWax::API;

my $log   = logger('plugin.squeezewax');
my $prefs = preferences('plugin.squeezewax');

# Only for a reply that carries no uri of its own, so the notice still links to
# the page the data came from. The same public page form Menu.pm links to.
use constant PAGE_URL => 'https://www.discogs.com/';

# Separators inside one line. Written as code points so this file stays ASCII.
use constant DASH => " \x{2013} ";
use constant DOT  => " \x{00B7} ";

# classifyResponse's vocabulary to the one line a failure shows (plan §4).
# Anything not named here - server_error, empty_body, malformed_json, unknown,
# no_response - is "did not answer".
my %ERROR_LINE = (
	unauthorized => 'PLUGIN_SQUEEZEWAX_DETAILS_UNAUTHORIZED',
	not_found    => 'PLUGIN_SQUEEZEWAX_DETAILS_NOT_FOUND',
);

# ---------------------------------------------------------------------------
# The two entry points: core's code-reference signature, so plain functions.
# ---------------------------------------------------------------------------

# ( $client, $callback, \%args, $releaseId, $linkCapable ). The passthrough is
# Menu.pm's: the id, and _itemFor's own link-capability answer for the menu this
# entry was built in, so a player is told apart by exactly the test that decided
# whether it got links.
sub _releaseDetails {
	my ( $client, $callback, undef, $releaseId, $linkCapable ) = @_;

	return _open( $callback, 'release', $releaseId, $linkCapable );
}

sub _masterDetails {
	my ( $client, $callback, undef, $masterId, $linkCapable ) = @_;

	return _open( $callback, 'master', $masterId, $linkCapable );
}

# ---------------------------------------------------------------------------
# One open.
# ---------------------------------------------------------------------------

sub _open {
	my ( $callback, $kind, $id, $linkCapable ) = @_;

	# The ids come from our own table, so this is a guard against a bad row, not
	# against the user. Nothing that is not a Discogs id goes into a path.
	return $callback->( [ _text( string('PLUGIN_SQUEEZEWAX_DETAILS_NOT_FOUND') ) ] )
		unless defined $id && $id =~ /^\d+$/;

	my $token = $prefs->get('discogsToken');

	return $callback->( [ _text( string('PLUGIN_SQUEEZEWAX_DETAILS_NO_TOKEN') ) ] )
		unless defined $token && $token ne '';

	if ( my $wait = Plugins::SqueezeWax::API->rateWait ) {
		main::INFOLOG && $log->is_info
			&& $log->info("details: $kind $id not fetched, the rate budget is spent");

		return $callback->( [ _busy($wait) ] );
	}

	my $path = $kind eq 'release' ? "/releases/$id" : "/masters/$id";

	my ( $url, @headers ) = Plugins::SqueezeWax::API->buildRequest( $path, {}, $token );

	# One callback for both outcomes, the response carried separately on the
	# error path: onError sets neither code nor headers on the object and passes
	# the HTTP::Response as its third argument (SimpleAsyncHTTP.pm:76-101, :96).
	# Derive.pm's _fire has the whole argument.
	my $done = sub {
		my ( $http, undef, $response ) = @_;

		_handle( $http, $response, $callback, $kind, $id, $path, $linkCapable );
	};

	Slim::Networking::SimpleAsyncHTTP->new( $done, $done, { timeout => 15 } )
		->get( $url, @headers );

	return;
}

sub _handle {
	my ( $http, $response, $callback, $kind, $id, $path, $linkCapable ) = @_;

	my $code    = $http->code;
	my $content = $http->content;
	my $headers = $http->headers;

	if ( !defined $code && $response ) {
		$code    = $response->code;
		$content = $response->content;
		$headers = $response->headers;
	}

	my $result = Plugins::SqueezeWax::API->classifyResponse( $code, $content );

	# Once per reply, whatever it returned: a 429 costs budget too.
	Plugins::SqueezeWax::API->noteResponse(
		Plugins::SqueezeWax::API::_parseRateHeaders($headers), time() );

	# One line per request, so a hardware check can count requests per open.
	main::INFOLOG && $log->is_info
		&& $log->info( "details: GET $path -> "
			. ( $result->{ok} ? 'ok' : ( $result->{error} || 'unknown' ) ) );

	if ( !$result->{ok} ) {
		my $error = $result->{error} || '';

		return $callback->( [ _busy( Plugins::SqueezeWax::API->rateWait
			|| Plugins::SqueezeWax::API::WINDOW_SECONDS ) ] )
			if $error eq 'rate_limited';

		return $callback->( [ _text( string(
			$ERROR_LINE{$error} || 'PLUGIN_SQUEEZEWAX_DETAILS_NO_ANSWER' ) ) ] );
	}

	my $data = ref $result->{data} eq 'HASH' ? $result->{data} : {};

	my $currency = $prefs->get('discogsCurrency');

	my @lines = $kind eq 'release'
		? _releaseLines( $data, $currency )
		: _masterLines( $data, $currency );

	return $callback->( [
		( map { _text($_) } @lines ),
		_notice( $data->{uri} || PAGE_URL . "$kind/$id", $linkCapable ),
	] );
}

# ---------------------------------------------------------------------------
# The lines. Pure: a decoded reply and the currency label in, strings out.
# ---------------------------------------------------------------------------

# Plan §2, release details 1-6. A line whose fields are all missing is left out,
# never shown blank; a line missing one of its fields shows the rest.
sub _releaseLines {
	my ( $data, $currency ) = @_;

	my $label = ref $data->{labels}  eq 'ARRAY' ? $data->{labels}[0]  : undef;
	my $format = ref $data->{formats} eq 'ARRAY' ? $data->{formats}[0] : undef;
	my $community = ref $data->{community} eq 'HASH' ? $data->{community} : {};
	my $rating = ref $community->{rating} eq 'HASH' ? $community->{rating} : {};

	return grep { defined } (
		_join( DASH, ref $label eq 'HASH' ? ( $label->{name}, $label->{catno} ) : () ),
		_join( DOT,
			Plugins::SqueezeWax::API::_formatLabel($format),
			$data->{country},
			$data->{released_formatted} ),
		_genreLine($data),
		_join( DOT,
			_present( $community->{have} )
				? sprintf( string('PLUGIN_SQUEEZEWAX_DETAILS_HAVE'), $community->{have} ) : undef,
			_present( $community->{want} )
				? sprintf( string('PLUGIN_SQUEEZEWAX_DETAILS_WANT'), $community->{want} ) : undef ),
		_ratingLine($rating),
		_forSaleLine( $data, $currency ),
	);
}

# Plan §2, master details 1-3.
sub _masterLines {
	my ( $data, $currency ) = @_;

	return grep { defined } (
		_present( $data->{year} ) && $data->{year}
			? sprintf( string('PLUGIN_SQUEEZEWAX_DETAILS_YEAR'), $data->{year} ) : undef,
		_genreLine($data),
		_forSaleLine( $data, $currency ),
	);
}

sub _genreLine {
	my ($data) = @_;

	my @genres = grep { _present($_) } @{ ref $data->{genres} eq 'ARRAY' ? $data->{genres} : [] };
	my @styles = grep { _present($_) } @{ ref $data->{styles} eq 'ARRAY' ? $data->{styles} : [] };

	return _join( DOT, join( ', ', @genres ), join( ', ', @styles ) );
}

# "Rating 4.1 / 5 (109 ratings)". Left out when nobody has rated the release:
# Discogs reports that as an average of 0 over 0 ratings, and "0.0 / 5" would
# read as a verdict.
sub _ratingLine {
	my ($rating) = @_;

	return undef unless _present( $rating->{average} ) && $rating->{count};

	return sprintf( string('PLUGIN_SQUEEZEWAX_DETAILS_RATING'),
		sprintf( '%.1f', $rating->{average} ), $rating->{count} );
}

# Plan §2 line 6. An unlabelled price is never shown (§15.31 ruling 15): with no
# currency stored, the count only. The code goes after the figure exactly as
# Discogs spells it, so there is no symbol table to get wrong.
sub _forSaleLine {
	my ( $data, $currency ) = @_;

	my $count = $data->{num_for_sale};
	my $price = $data->{lowest_price};

	return undef unless _present($count);

	return string('PLUGIN_SQUEEZEWAX_DETAILS_NONE_FOR_SALE')
		if !$count || !_present($price);

	return sprintf( string('PLUGIN_SQUEEZEWAX_DETAILS_FOR_SALE'), $count )
		unless _present($currency);

	return sprintf( string('PLUGIN_SQUEEZEWAX_DETAILS_FOR_SALE_FROM'),
		$count, sprintf( '%.2f', $price ), $currency );
}

# The notice (plan §2.1). In an app that can open links, one item, linked, and -
# as everywhere else in this plugin - with no rel. On a player, the text and then
# the address as plain text, without its scheme; a weblink there would be a row
# that does nothing.
sub _notice {
	my ( $uri, $linkCapable ) = @_;

	my $notice = string('PLUGIN_SQUEEZEWAX_DETAILS_NOTICE');

	return { type => 'text', name => $notice, weblink => $uri } if $linkCapable;

	( my $plain = $uri ) =~ s{^https?://}{};

	return ( _text($notice), _text($plain) );
}

sub _busy {
	my ($wait) = @_;

	return _text( sprintf( string('PLUGIN_SQUEEZEWAX_DETAILS_BUSY'), $wait ) );
}

sub _text {
	my ($name) = @_;

	return { type => 'text', name => $name };
}

# The present parts joined, or undef when there are none.
sub _join {
	my ( $sep, @parts ) = @_;

	@parts = grep { _present($_) } @parts;

	return @parts ? join( $sep, @parts ) : undef;
}

sub _present {
	my ($v) = @_;

	return defined $v && !ref $v && $v =~ /\S/;
}

1;
