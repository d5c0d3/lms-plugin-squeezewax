package Plugins::SqueezeWax::Plugin;

use strict;

use base qw(Slim::Plugin::Base);

use Slim::Utils::Log;

use Plugins::SqueezeWax::Schema;

my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.squeezewax',
	description  => 'PLUGIN_SQUEEZEWAX_NAME',
	defaultLevel => 'WARN',
});

sub initPlugin {
	my $class = shift;

	Plugins::SqueezeWax::Schema->init();

	$class->SUPER::initPlugin(@_);
}

1;
