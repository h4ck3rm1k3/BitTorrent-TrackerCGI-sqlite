#!/usr/bin/perl 
use lib "/pine02/www/tracker/BitTorrent-TrackerCGI-sqlite/lib";
#use BitTorrent::TrackerCGI;
#print "Hello";

## gs()gluelogic.com

## Be very careful with what is called from this script.  At Apache startup,
## it will be included into the Apache mod_perl server.  Anything run at
## that point is run under user root.  (You should only be including libraries
## here.)  Therefore, do not include here any code to which a non-root and 
## non-admin user has write privileges.

use strict;

## ----------
## ----------

## This section is similar in scope to Apache::Debug.
## Delivers a stack backtrace to the error log when perl code dies.

## Allocate 64K as an emergency memory pool for use in out of memory situation
$^M = 0x00 x 65536;

## Little trick to initialize this routine here so that in the case of OOM,
## compiling this routine doesn't eat memory from the emergency memory pool $^M
use CGI::Carp ();
eval { CGI::Carp::confess('init') };

## Importing CGI::Carp sets $main::SIG{__DIE__} = \&CGI::Carp::die;
## Override that to additionally give a stack backtrace
$main::SIG{__DIE__} = \&CGI::Carp::confess;

## ----------
## ----------

## Preload often-used modules into the main httpd server 
## so that they are shared between all httpd children.

## Need these two in specific order to avoid segv in mod_perl 1.2.6 + Perl 5.6.1
use DynaLoader ();
use XSLoader ();

use Exporter ();
use POSIX ();
use Socket ();
use Symbol ();

#use Apache ();
use Apache2::Const -compile => qw(OK DECLINED M_GET M_POST M_OPTIONS HTTP_METHOD_NOT_ALLOWED);
use Apache2::RequestRec;
use APR::Table ();
use Apache2::RequestIO ();

# Make sure Apache children do not grow too large (memory usage)
# Set generous memory size limit and do not check too often
# use Apache::SizeLimit ();
# $Apache::SizeLimit::MAX_PROCESS_SIZE       = 16384;
# $Apache::SizeLimit::CHECK_EVERY_N_REQUESTS = 16;
# $Apache::SizeLimit::MIN_SHARE_SIZE         = 2048;
# $Apache::SizeLimit::MAX_UNSHARED_SIZE      = 8192;

## Load a Perl interface to the Apache API
## (unused)
#use Apache::RegistryBB ();

## This is SO chunky.  It adds > 2 MB to Apache children!
## This is the recommended way to call CGI.pm v2.46 and up for use in mod_perl.
## (unused)
#use CGI qw(-compile :all);

## ----------
## ----------

## install database driver and preload database modules
## adds about 3 MB to memory usage, but it will be shared.
## However, these drivers seem to leak on USR1 signal,
## so perform a shutdown/restart when updating the server
use Apache::DBI ();  ## (MUST be before DBI.pm)
use DBI ();
DBI->install_driver('SQLite');
use DBD::SQLite();
Apache::DBI->connect_on_init
  (
    'DBI:SQLite:database=/var/www/tracker/bittracker.sqlite',"","",
    {
	PrintError => 1,	# warn() on errors
	RaiseError => 1,	# do not die on error
	AutoCommit => 1		# commit executes immediately
    }
  );

## ----------
## ----------

## Local libraries



## BitTorrent tracker
use BitTorrent::Tracker ();


1;
