package Plugins::SqueezeWax::Plugin;

use strict;

use base qw(Slim::Plugin::Base);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::SqueezeWax::Schema;

# WARN, matching Importer.pm's registration of the same category and both
# reference plugins (refs/lms-plugin-tidal/Plugin.pm:18-22).
#
# Step 2 used INFO because our own handful of lines were the only evidence of a
# healthy run. That stopped being true once the importer had a row in the scan
# progress UI and LMS's own "Starting/Completed ... Scan" pair in scanner.log
# (Slim/Music/Import.pm:578, :710-712) - neither of which needs the category
# turned up. The one thing those cannot report, "examined 4,800, confirmed 0",
# is escalated to warn by the importer itself.
my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.squeezewax',
	description  => 'PLUGIN_SQUEEZEWAX_NAME',
	defaultLevel => 'WARN',
});

my $prefs = preferences('plugin.squeezewax');

# discogsMaxTier is gone (decisions §15.8); drop it from existing prefs files.
# File scope, not initPlugin and not under main::WEBUI: the WEBUI block below is
# the only place Settings.pm is loaded, so a migration there would never run on
# a headless server (decisions §15.12 part 3). The scanner never loads this file
# (Slim/Utils/PluginManager.pm:204), so one process writes the prefs file. Same
# pattern as Slim/Plugin/Podcast/Plugin.pm:34-40. `remove` also drops the
# _ts_discogsMaxTier twin and saves (Slim/Utils/Prefs/Base.pm:242-258).
$prefs->migrate(1, sub { $_[0]->remove('discogsMaxTier'); 1 });

sub initPlugin {
	my $class = shift;

	# Same rationale as Importer::initPlugin: proof this entry point ran.
	main::INFOLOG && $log->is_info
		&& $log->info( 'Plugin loaded (' . ( main::SCANNER ? 'scanner' : 'server' ) . ' process)' );

	Plugins::SqueezeWax::Schema->init();

	# Only the server has a web UI; the scanner never loads this file anyway
	# (Slim/Utils/PluginManager.pm:204). Guarded and required lazily as
	# refs/lms-plugin-tidal/Plugin.pm:60-66 does.
	if (main::WEBUI) {
		require Plugins::SqueezeWax::Settings;
		Plugins::SqueezeWax::Settings->new();
	}

	$class->SUPER::initPlugin(@_);
}

1;
