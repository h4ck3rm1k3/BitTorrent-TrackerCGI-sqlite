#!/usr/bin/perl 
#warn "start up script started\n";
#use lib "/home/h4ck3rm1k3/perl5/lib/perl5";
#use lib "/home/h4ck3rm1k3/perl5/share/perl5";
#use lib "/pine02/www/tracker/BitTorrent-TrackerCGI-sqlite/lib";
use lib "/home/mdupont/experiments/fosm/tracker/BitTorrent-TrackerCGI-sqlite/lib";

use strict;
use DynaLoader ();
use XSLoader ();
use Exporter ();
use POSIX ();
use Socket ();
use Symbol ();
# use Apache2::Const -compile => qw(OK DECLINED M_GET M_POST M_OPTIONS HTTP_METHOD_NOT_ALLOWED);
# use Apache2::RequestRec;
# use APR::Table ();
# use Apache2::RequestIO ();
# use Apache::DBI ();  ## (MUST be before DBI.pm)
use DBI ();
DBI->install_driver('SQLite');
use DBD::SQLite();
use BitTorrent::Tracker;
use HTTP::Engine;
use Plack::Loader;

my $engine = HTTP::Engine->new(
    interface => {
	module => 'PSGI',
	request_handler => \&BitTorrent::Tracker::handler
    },
  );
my $app = sub { $engine->run(@_) };
Plack::Loader->load('Standalone', port => 8081)->run($app); # see L<Plack::Server::Standalone> and  L<Plack::Loader>

1;
