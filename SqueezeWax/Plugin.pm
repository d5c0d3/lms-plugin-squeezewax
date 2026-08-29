package Plugins::SqueezeWax::Plugin;

use strict;

use base qw(Slim::Plugin::Base);

use Slim::Utils::Log;

use Plugins::SqueezeWax::Schema;

# INFO, not refs/lms-plugin-tidal and refs/Spotty-Plugin's WARN: those plugins
# log per-request detail at INFO, which would be noise by default. Ours logs a
# handful of lines per session (see Schema.pm), so INFO by default is exactly
# what makes a healthy run visible without the user touching
# Settings -> Advanced -> Logging. Must match Importer.pm's registration of
# the same category.
my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.squeezewax',
	description  => 'PLUGIN_SQUEEZEWAX_NAME',
	defaultLevel => 'INFO',
});

sub initPlugin {
	my $class = shift;

	# Same rationale as Importer::initPlugin: proof this entry point ran.
	main::INFOLOG && $log->is_info
		&& $log->info( 'Plugin loaded (' . ( main::SCANNER ? 'scanner' : 'server' ) . ' process)' );

	Plugins::SqueezeWax::Schema->init();

	$class->SUPER::initPlugin(@_);
}

1;
