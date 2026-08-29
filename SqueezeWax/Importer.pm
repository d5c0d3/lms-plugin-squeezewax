package Plugins::SqueezeWax::Importer;

# Scanner-side entry point, named by <importmodule> in install.xml.
#
# The scanner never loads Plugin.pm: Slim::Utils::PluginManager::load skips any
# plugin without an <importmodule> and initialises only that class
# (Slim/Utils/PluginManager.pm:204). So anything the importer needs - log
# category, schema attach - has to be registered from here as well.
#
# Nothing else lives here yet. Matching arrives in build-order steps 3-5, and
# the Slim::Music::Import->addImporter registration comes with it: registering
# an importer whose startScan does nothing would only put a dead row in the
# scan progress UI.

use strict;

use Slim::Utils::Log;

use Plugins::SqueezeWax::Schema;

sub initPlugin {
	my $class = shift;

	# Without this the category inherits the root logger's level in the
	# scanner. Safe to call from both entry points - it only sets a level and
	# a description (Slim/Utils/Log.pm:378-417).
	Slim::Utils::Log->addLogCategory({
		category     => 'plugin.squeezewax',
		description  => 'PLUGIN_SQUEEZEWAX_NAME',
		defaultLevel => 'WARN',
	});

	Plugins::SqueezeWax::Schema->init();

	return 1;
}

1;
