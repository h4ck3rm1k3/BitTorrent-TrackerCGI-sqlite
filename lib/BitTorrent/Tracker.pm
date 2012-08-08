#!/usr/bin/perl -Tw
# from http://www.gluelogic.com/code/BitTorrent/TrackerCGI.pm
package BitTorrent::Tracker;
use strict;
use warnings;
use APR::Table ();
use Carp qw(confess cluck);
use DBD::SQLite();
use DBI;
use Digest::SHA1 ();
use File::Find ();
use BitTorrent::TrackerCore qw( bencode_dict Connect  parse_query_string %cgi QSTR ATTR_USE_RESULT CreateTables summary_sha1 BT_EVENTS bt_send_peer_list bt_peer_started bt_peer_stopped bt_peer_progress refresh_summary REFRESH_INTERVAL MAX_PEERS TORRENT_BASE_URL );
use Data::Dumper;


## BitTorrent::TrackerCGI
##
##   mod_perl implementation of BitTorrent tracker, using SQLite3 for storage
##
##
## Copyright (c) 2003  Glue Logic LLC  All rights reserved  code()gluelogic.com
##
## This program is free software; you can redistribute it and/or
## modify it under the terms of the GNU General Public License
## as published by the Free Software Foundation; either version 2
## of the License, or (at your option) any later version.
##
## This program is distributed in the hope that it will be useful,
## but WITHOUT ANY WARRANTY; without even the implied warranty of
## MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
## GNU General Public License for more details.
##
## You should have received a copy of the GNU General Public License
## along with this program; if not, write to the
##   Free Software Foundation, Inc.
##   59 Temple Place - Suite 330
##   Boston, MA 02111-1307, USA
##
## Full text of the GNU General Public License may be found at:
##   http://www.gnu.org/copyleft/gpl.html
##
##
## TrackerCGI.pm also runs as a CGI, but is slow
## Idea for a Perl CGI tracker from PHPBTTracker http://dehacked.2y.net:6969/

## 2003.08.08  v0.01  code()gluelogic.com  alpha 1
## 2004.11.08  v0.02  code()gluelogic.com
##   fixed code that generates RSS to properly generate <enclosure> tag
##     (thx David (labarks at comcast))
## 2012.08.05 v0.03 hacked by James Michael DuPont<jamesmikedupont@gmail.com>

$BitTorrent::TrackerCGI::VERSION || 1;          # (eliminate Perl warning)
$BitTorrent::TrackerCGI::VERSION  = 0.03;


BEGIN {
  use constant MOD_PERL => exists($::ENV{'MOD_PERL'})
    ? (require('mod_perl.pm'), $mod_perl::VERSION >= 1.99)
	? $mod_perl::VERSION
	: 1
    : 0;

}


## send error message via BitTorrent protocol
##  bt_error($message)
sub bt_error {
    my $res =shift;
    my $reason =shift||die "no param";
    print STDOUT ${bencode_dict({ 'failure reason' => $reason })};
    return $res; ## Apache::OK, and boolean false
}

## send HTTP 400 Bad Request and error message
##  bad_request($r, $message)
sub bad_request {
    my $res = shift|| confess "no request";
    my $status = shift|| confess "no status";
    my $string = shift|| confess "no string";
    $res->status($status);  ## 302 Found (generic Temporary Redirect)
    $res->headers->header('Location' , TORRENT_BASE_URL.'/');
    $res->headers->header('content_type' , 'text/plain; charset=ISO-8859-1');
    $res->body($string . "\nThis resource is for use by BitTorrent clients.\n");    
    return $res; ## Apache::OK
}

## send standard headers once ready to speak BitTorrent protocol
## mark as uncacheable, set binary content-type, and close the connection
## to free up server-side resources quickly since no keepalives or pipelines
## are used in the BitTorrent protocol.  Just serve each peer as quickly as
## possible when it makes a single request every REANNOUNCE_INTERVAL
sub send_bt_http_headers {
    my $res = shift;
#    cluck "send_bt_http_headers:". $res;
    $res->status(200);
    $res->headers->header('Cache-Control','no-cache'); #    $res->no_cache(1);
    $res->headers->header('Connection','close');
    $res->headers->header('content_type' , 'text/plain; charset=ISO-8859-1');
#    binmode(STDOUT,':raw') unless (MOD_PERL);
}


#our($dbh,%cgi,@params);

# this is the webserver specific code, the generic code has been refactored for testing. 
sub bt_scrape {

    my $r = shift || confess "missing peer";;

    BitTorrent::TrackerCore::bt_scrape($r);

    ## Run cleanup if refresh interval has elapsed.
    check_last_update($r);
}

sub check_last_update {
    my $r=shift|| confess "missing request";;

    ## Run cleanup if the refresh interval has elapsed.
    ## Clean timed out entries from peer/scc hash tables at regular intervals.
    ## There exists a condition whereby if no requests come after the refresh
    ## interval has elapsed, the table will remain stale.  For this reason, it
    ## is recommended that a cron job augment or even replace refresh_summary().
    ## (cron job could check summary table and walk tables for expired peers,
    ##  simply by executing 'perl -T TrackerCGI.pm refresh)
    my $now = $^T;
    if ($BitTorrent::TrackerCGI::mark < $now - REFRESH_INTERVAL) {
#	$r->rflush();
#	close(STDOUT);  ## no keepalive requests; finish connection quickly 
	# causes : Filehandle STDOUT reopened as GEN0 only for input
	refresh_summary($now);
    }
}

use Plack::Request;
use Carp qw(cluck);

sub handler {
    my $r = shift|| die "no env";
    my $method = $r->method || "NONE";
    my $res = HTTP::Engine::Response->new;   
    unless ($r->method eq "GET") {
	$res->status(405);
	return $res;
    }

    #'PATH_INFO' => '/favicon.ico',
    if ($r->uri =~ m|^/favicon\.ico|) 
    {
	$res->status(404);
	return $res;
    }

    my $dbh = BitTorrent::TrackerCore::Connect();
    my $params = $r->parameters();
    for my $k (keys %{$params}) {

	if ($k eq "info_hash") {
	    warn "Param $k:". unpack("H*",$params->{$k}) . "\n";
	} else {
	    warn "Param $k:". $params->{$k} . "\n";
	}
	$cgi{$k}= $params->{$k};
    } 
    my $path_info = $r->path_info;

    #shorten it
#    $path_info =~ s|/tracker/BitTorrent-TrackerCGI-sqlite/tracker/announce|/announce|;
#    $path_info =~ s|/tracker/BitTorrent-TrackerCGI-sqlite/tracker/scrape/|/scrape/|;

    warn "New Path Info" . $path_info . "\n";

    if ($path_info ne '/announce') {	    

	if ($path_info eq '/scrape') {
	    send_bt_http_headers($res);
	    bt_scrape($r);
	    return $res; ## Apache::OK
	}
	elsif ($path_info eq '/forcerefresh') {
	    Connect();
	    refresh_summary($^T);
	    return $res; ## Apache::OK
	}
	elsif ($path_info eq '/install') {
	    CreateTables;
	}
	else {
	    return bad_request($res, 400, 'Invalid path info in request. Expecting announce or scrape, We got '. $path_info);
	}
    }

    ## validate parameters for other actions
    ## ($x !~ tr/0-9//c is equivalent to $x =~ /^\d+$/)
    ## (negative numbers not allowed with the below tr/0-9//c)
    ## (port numbers not allowed below 1024 for sanity in CHECK_PEER connect()s)
    my $cgi= \%cgi;


    foreach my $f (	qw( info_hash  peer_id uploaded downloaded left port   ))  {
	if (! (defined($cgi->{$f}))) {
	    warn "Missing field:" . $f;
	    cluck "Error:" . Dumper($cgi);
	    return bad_request($res, 400, 'Missing ' . $f)  ;
	}
    }

    # default value 
    $cgi->{'numwant'} = MAX_PEERS
      if (!defined($cgi->{'numwant'}) || $cgi->{'numwant'} > MAX_PEERS);

    # default field IP
    {
	my $f = 'ip';
	if (! (defined($cgi->{$f}))) {
	    ($cgi->{'ip'}) = ($r->address) =~ /^(.+)$/;
	    warn "Missing IP:" . $f . " using " . $cgi->{'ip'} . "\n";

	    ($cgi->{'ip'}) = ($cgi->{'ipv6'}) =~ /^(.+)$/; # ipv6
	    warn "Missing IP:" . $f . " using IPV6" . $cgi->{'ip'} . "\n";
	}
    }

    # default field left
    {
	my $f = 'last';
	if (! (defined($cgi->{$f}))) {
	    warn "Missing field:" . $f;
	    $cgi->{$f}= "0"; # default 
	    #DONT return bad_request($r, 400, 'Missing ' . $f)  ;
	}
    }
    
    return bad_request($res, 400, 'infohash wrong size.') unless  length($cgi->{'info_hash'}) == 20;
    return bad_request($res, 400, 'peer_id wrong size.')  unless  length($cgi->{'peer_id'}) == 20;
    return bad_request($res, 400, 'ip wrong size.')  unless  length($cgi->{'ip'}) < 128;

##
    foreach my $f (qw(uploaded downloaded left last numwant) )     {
	return bad_request($res, 400, 'Bad format ' . $f)  unless (
	    $cgi->{$f}       !~ tr/0-9//c
	    );
    }
    
    foreach my $f (qw(port) ) {
	return bad_request($res, 400, 'Bad format ' . $f)  unless (
	    $cgi->{$f}       =~ /^(\d+)/
	    && $1 > 1023  
	    && $1 < 65536 
	    && ($cgi->{'port'} = $1) # untaint
	    );
    }

    $cgi->{'event'} ||= '';

    ## check requested action
    exists(BitTorrent::TrackerCore::BT_EVENTS->{$cgi->{'event'}})
      || return bad_request($res, 400, "Invalid 'event' requested.");

    ## send HTTP headers, subsequent errors must be sent via BitTorrent protocol
    send_bt_http_headers($res);

    ## get torrent info (validate torrent exists in database)
    warn "Going to prepare db:" . QSTR->{'summary_sha1'} . "\n";
    if (DBI->err) {
	warn  "Database error:". DBI->err;
    }

    my $summary_sha1 =
      $dbh->prepare_cached(QSTR->{'summary_sha1'}, ATTR_USE_RESULT);

    if ($summary_sha1->err) {
	warn  "Database error:". $summary_sha1->err;
    }

    warn "Going to look for SHA:" .
	$summary_sha1 .  
	" info hash:".  unpack("H*",$cgi->{'info_hash'}) ."in the database\n";

    #if ($sth->err) warn  "Database error:". $sth->err;

    my $torrent =summary_sha1($cgi->{'info_hash'}) || (
	!DBI->err
	? return bt_error($res,'Requested torrent not available on this tracker.' 
			  . ",summary_sha1 :" . unpack("H*",$summary_sha1 )
			  . ",info_hash:" . unpack("H*",$cgi->{'info_hash'})
	)
	: return bt_error($res,'database error')
	);


    ## get peer info, execute action, and send peers list (if action succeeds)
    my $info_get = $dbh->prepare_cached(QSTR->{'info_get'},
					ATTR_USE_RESULT);
    my $peer =
      $dbh->selectrow_hashref($info_get, undef, $cgi->{'peer_id'})
      || (!DBI->err ? +{} : return bt_error($res,'database error'));

    my $status = BitTorrent::TrackerCore::BT_EVENTS->{$cgi->{'event'}}->($peer); # this could cause an error
    
    if ($status eq "1")
    {
	warn "Status :$status";
	bt_send_peer_list($torrent);
    }
    else
    {
	bt_error($res,$status);# error
    }
    ## Run cleanup if refresh interval has elapsed.
    check_last_update($r);

    $res->status(200);  ## 200 OK

    return $res;
    
}

## Run as CGI.  If no args passed, CGI mode, else if 'refresh' set up db tables.
##
## The overhead of DBI.pm and DBD::mysql is substantial, so it is highly
## recommended that BitTorrent::TrackerCGI be run under mod_perl rather than
## as a CGI.  On a PII-400, running as a CGI takes 0.4 seconds.
##
## Database (tablespace), dbuser, and dbpass must already have been set up.
## Note that if this is a CGI, then ISINDEX args could be passed to the web
## server if the admin has not smartly disabled the passing of ISINDEX-style
## args to CGI.  (In Apache, this is "CGICommandArgs off".  Currently, the
## defaults to ON in Apache (bad!)).  In any case, it is not a problem to run
## the db table install routine multiple times, so no attempt is made to detect
## if QUERY_STRING contains ISINDEX-style args.

## MAX_ROWS is used in database table creation
## (must 'alter table' after tables created; changing this will have no effect)
## Note: MAX_ROWS is only advisory to MySQL to help it choose pointers sizes
sub Main 
{
    my $dbh=Connect();

    if (!MOD_PERL && $ARGV[0] eq 'force-refresh') {
    print "Content-type: text/plain; charset=ISO-8859-1\n\n"
	if (exists $::ENV{'GATEWAY_INTERFACE'});

    refresh_summary($^T);
    print "\ndone\n\n";
}
elsif (!MOD_PERL && $ARGV[0] eq 'refresh') {
    print "Content-type: text/plain; charset=ISO-8859-1\n\n"
      if (exists $::ENV{'GATEWAY_INTERFACE'});

	exit(1);
    }

    ## database (BT_DB_NAME) must already have been created in advance, just
    ## like db user (BT_DB_USER) and db password (BT_DB_PASS)
    ## (If you change the size of bt_names.name VARCHAR(92), you must change
    ##  the places in the file that hard-code this length; just search for "92")

    CreateTables();

    ## set up torrents in torrents directory
    refresh_summary($^T);

    print "\ndone\n\n" unless (exists $::ENV{'CRON'});
}


1;
__END__

Assorted Notes:
---------------

Security: because of no authentication, any peer can contact a tracker and mess
up what the tracker thinks is the state of any downloader.  Also, all statistics
are manipulatable.

This module requires a few RPMs possibly not installed by default on your
Linux distribution.  On RedHat, these might include perl-DBI-*.i386.rpm,
perl-DBD-MySQL-*.i386.rpm, and perl-Digest-SHA1-*.i386.rpm.  Apache::DBI is
also recommended (but not required) for database connection caching, and
usually needs to be added to the system.

HEAP tables are fast and stored in B-trees.  However, their entire contents are
  lost when the database server is stopped (shut down).  The dynamic tables
  keeping track of current downloaders bt_info and bt_data will be completely
  regenerated within the reannounce interval by those downloaders still alive,
  so there is no loss there.  Also, the tables could be regenerated by replaying
  the web log GET requests.
HEAP type tables do not support AUTO_INCREMENT colums; MyISAM tables do.
HEAP tables must have fixed length records.  Resolve and store packed IP address
  to both save space and to avoid a long CHAR() column for ip (not VARCHAR()).
  For trackers that use DNS names that are multi-homed, we only use one address.
  If this is a big deal, maybe the client can check in with multiple addresses?

Similar to the IP address packing, the summary table and names tables are
separate so that the summary table can have a fixed record length.  The summary
table is used and updated much more heavily than the names table, which is only
accessed during refresh and by the scrape interface, and the name column is the
only VARCHAR column between the tables.

peer statistics are kept in bt_data, separate from peer info in bt_info so that
there is less contention between updating the items in the bt_data table on
every hit and choosing random entries from among the items in bt_info.  This
allows the updates to bt_data to be made low priority since the peer for which
the data is being updated probably will not be contacting the server for another
reannounce interval (30 minutes).

The statistics in the summary table may be completely regenerated from the web
server logs, although high traffic sites may wish to disable web logging for the
tracker.  [As an aside, for maximum performance, this code could be modified to
entirely eliminate the summary table, which would also disable the /scrape
interface.  Then, statistics could be generated from the web logs, or even those
can be disabled.]  All that said, for the typical site, bandwidth usage will
probably become a problem well before CPU, memory, or disk usage.

At the moment I am writing this, the bt_data and bt_info tables consume about
172 bytes per entry (total) including indexes were they MyISAM tables.
References:
  http://www.mysql.com/doc/en/Storage_requirements.html
  http://www.mysql.com/doc/en/Key_space.html
For convenience, let's assume the same is true for HEAP tables, which are purely
memory-based B-trees, and let's round up to 192 bytes, so that 16 entries
consume 3 KiB, and 32768 (32 Ki) entries consumes 6 MiB.  32 Ki simultaenous
downloaders is quite a lot.  Not many more than 4 Ki have been seen in the
field, and 4 Ki simultaenous downloaders consumes about 768 KiB of memory for
the HEAP tables, a minuscule amount of memory to require for the db tables on
any serious web server.

Now let's look at some other resource usage.  The default reannounce interval
is 30 minutes, and downloaders can announce themselves more frequently if they
need a new batch of peers.  4 Ki downloaders all announcing themselves once
every 30 minutes leads to an average of 2.3 hits per second, which is not
unreasonable to ask of a web server and database.  Of course, this assumes a
completely even distribution of accouncements from downloaders, which is not
realistic, so one must assume some quiet periods of fewer and some burst periods
of more requests.  In contrast, 32 Ki downloaders would indicate an average of
18.2 hits per second, which might indicate the need for a dedicated machine to
handle the load.

So now that we have established than an average box should be able to handle
4 Ki simultaneous downloaders, let's look at the bandwidth usage, since that is
probably a limiting factor for many, in speed and/or cost.  The typical HTTP
request + bencoded response of 50 peers, including HTTP protocol overhead, is
about 4 KiB.  With 4 Ki downloaders announcing themselves once every 30 minutes
over the course of a day this adds up to 768 MiB of throughput, and over the
course of a month adds up to 22.5 GB.  This assuming constant usage, which does
not happen often, but gives an approximate of the magnitude of what to expect
when running a popular tracker.  In practice, few torrents will ever see 4 Ki
simultaneous downloaders.

Bandwidth usage can be reduced by gzip'ing content to clients that support
gzip Content-encoding.  mod_gzip with Apache 1.3 series and mod_deflate with
Apache 2.0 series are highly recommended.

[Aside:
If you modify this code for us in a public torrent site, it is recommended that
web logs be disabled for privacy reasons.  If someone uploads a torrent for
illegal material -- which your site policy should clearly not allow -- you can
expect your responsibility to be to delete the torrent when informed by
authorities.  If you have web logs in addition, those may be subpoenaed by law
enforcement or by vigilantes like the RIAA or BSA while the authorities
help/turn a blind eye, causing you much time and grief and expense.  YMMV.
Try not to host torrents for any "questionable" material to begin with and you
will be better off.]

The auto-updated timestamp 'mark' column in bt_data is not indexed to avoid the
overhead of updating the index upon every hit.  After all, its value is only
accessed during cleanup (default 15 minutes; twice each reannounce interval),
so cleanup may be a bit slower because it has to run table scans for all the
cleanup queries.  Then again, these are HEAP tables (completely in memory), so
it may not matter much.  If refreshing takes too long, you might want to create
an index on 'mark'.  YMMV.  If you do, might also set PACK_KEYS=1.

There is probably some room to further tune interaction with the database.
We could write our own Apache::DBI for connection and statement caching
(prepare_cached) for additional performance, but more simple to use Apache::DBI
(and more future-proof for threaded Apache2 and mod_perl2) unless you _really_
need to avoid the method call and hash lookup.  For an example, see:
http://take23.org/docs/guide/performance.xml/10


Future possible extensions:
---------------------------
If there is a desire for it, information is already available to allow for a
limit to be placed on the maximum number of concurrent downloaders (peers+scc)
for a torrent, as well as the ratio of peers to scc for a torrent,
e.g. only allow 4*scc < peers+seeds.  To place a maximum across all torrents,
an additional query would need to be made to the database
(SELECT COUNT(*) FROM bt_info), but COUNT(*) queries without columns and without
a WHERE clause and FROM only one table are very fast in MySQL, so such a limit
would be trivial to implement and would have minimal impact as well.


Notes to self:
--------------
Are peer_ids unique between the same client downloading different torrents?
I assumed as such.  If this is not the case, I need to update the PRIMARY KEY
in bt_data table to be (sha1,peer_id) (after adding a sha1 column), and to
update appropriate WHERE clauses in numerous other queries.


See Also:
--------------
http://verysimple.com/2010/01/12/sqlite-lpad-rpad-function/
http://mail-archives.apache.org/mod_mbox/perl-modperl/200509.mbox/%3CPine.LNX.4.63.0509082243310.9521@theoryx5.uwinnipeg.ca%3E
http://www.perturb.org/display/entry/629/
http://www.sqlite.org/lang_insert.html
