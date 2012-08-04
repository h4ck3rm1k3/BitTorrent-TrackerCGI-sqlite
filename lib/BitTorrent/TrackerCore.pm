#!/usr/bin/perl -Tw
# from http://www.gluelogic.com/code/BitTorrent/TrackerCGI.pm
package BitTorrent::TrackerCore;
#use Devel::NYTProf::Apache;
#use Devel::NYTProf;
use strict;
use warnings;
use DBI ();
use DBD::SQLite();
use Digest::SHA1 ();
use File::Find ();
use File::Find;
use Digest::SHA1;
use Carp qw(cluck confess);

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(bt_error Connect bt_scrape parse_query_string %cgi QSTR ATTR_USE_RESULT CreateTables);


#use Bencode qw( bencode  ); #bdecode
#use Convert::Bencode qw( bencode bdecode); #
use Convert::Bencode_XS qw(bencode bdecode);

use APR::Table ();
use Errno ();
use Fcntl ();
use Socket;
use Symbol ();
use Data::Dumper;

our $dbh;
our @params;
our %cgi =();
our $debug=1;

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

##################
## config below ##
##################


## TORRENT_BASE_URL, TORRENT_PATH, and the database connection
## info MUST be changed. The rest may be left at their defaults.

## Base URL to torrents (trailing directory '/' is not necessary)
use constant TORRENT_BASE_URL	=> 'http://localhost/torrents';
## URL of the tracker (with /announce suffix path_info)
use constant TRACKER_URL	=> 'http://localhost/tracker/announce';

## Filesystem path under which to find .torrent files (MUST end with '/')
use constant TORRENT_PATH	=> '/var/www/torrents/';
## Path to which to write torrent statistics HTML table
use constant TORRENT_STATS_FILE	=> TORRENT_PATH.'/bt_stats.inc';
## Path to which to write torrent RSS XML <item>s
use constant TORRENT_RSS_FILE	=> TORRENT_PATH.'/bt_rss.inc';

## Check if peers are reachable.  Set to 0 to disable.  Set to 1 to enable.
use constant CHECK_PEER		=>    1;
## Number of peers to send in one request
use constant MAX_PEERS		=>   50;
## Maximum reannounce interval (in seconds) (1800 == 30 mins)
use constant REANNOUNCE_INTERVAL=> 1800;
## Minimum reannounce interval (in seconds) ( 300 ==  5 mins)
use constant REANNOUNCE_MIN	=>  300;
## Maximum age last update can reach before expiring downloader (in seconds)
use constant TIMEOUT_INTERVAL	=>    1.5*REANNOUNCE_INTERVAL;
## Frequency for which to clear expired entries from database
## (clear expired entries from database twice every reannounce period)
use constant REFRESH_INTERVAL	=>    0.5*REANNOUNCE_INTERVAL;
## HTML for image to use in for 'info' icon on stats page (e.g. '<img src=...>')
use constant INFO_IMG		=> 'i';


##################
## config above ##
##################

## 2003.08.08  v0.01  code()gluelogic.com  alpha 1
## 2004.11.08  v0.02  code()gluelogic.com
##   fixed code that generates RSS to properly generate <enclosure> tag
##     (thx David (labarks at comcast))
$BitTorrent::TrackerCGI::VERSION || 1;          # (eliminate Perl warning)
$BitTorrent::TrackerCGI::VERSION  = 0.02;

## array ref for convenience and to ensure same settings used on all connect()s
use constant BT_DB_INFO	=>[
    'DBI:SQLite:database=/var/www/tracker/bittracker.sqlite',
    "", "",
    { PrintError=>1, RaiseError=>1, AutoCommit=>1 } 
];



BEGIN {

  $BitTorrent::TrackerCGI::mark = 0;
  $::ENV{'PATH'} = "/bin:/usr/bin"; ## (for taint mode safety)

}

## SQL query strings
## Collected here for convenience and consistency.
## (using placeholders automatically invokes $dbh->quote() on args; safe!)
## (It is not necessary for all of these to use $dbh->prepare_cached())
use constant ATTR_USE_RESULT => {  };
use constant QSTR =>
  {
'summary_sha1'		=>  "SELECT peers,seeds FROM bt_summary WHERE sha1=?",

'summary_update'	=>  "UPDATE bt_summary SET peers=peers+?,seeds=seeds+?, scc=scc+?, done=done+?,trans=trans+? WHERE sha1=?",

'data_add'		=>  "INSERT OR REPLACE  INTO bt_data (pend, upld, dnld, mark, peer_id) values (?,?,?,NULL,?)",

'data_update'		=>  "UPDATE bt_data SET pend=?,upld=?,dnld=?,mark=NULL WHERE peer_id=?",

'data_delete'		=>  "DELETE  FROM bt_data WHERE peer_id=?",

'info_get'		=>  "SELECT ip,status FROM bt_info WHERE peer_id=?",

'info_add'		=>  "INSERT OR REPLACE INTO bt_info (ip,port,peer_id, sha1) values (?,?,?,?)", #INET_ATON(

'info_peer_to_seed'	=>  "UPDATE bt_info SET status='seed' WHERE peer_id=?",

'info_delete'		=>  "DELETE FROM bt_info WHERE peer_id=?",

'pgroup_not_scc'	=>  "SELECT ip AS ip, port, substr(peer_id || '                    ', 1, 20) AS 'peer id' FROM bt_info WHERE sha1=? AND status != 'scc' LIMIT ?,?",

'pgroup_only_peers'	=>  "SELECT ip AS ip, port,substr(peer_id || '                    ', 1, 20) AS 'peer id' FROM bt_info WHERE sha1=? AND status = 'peer' LIMIT ?,?"
  };

## encoding and decoding binary data to/from a string of hexadecimal pairs
#sub bin2hex { unpack('H*',$_[0]) }   ##  bin2hex($binary_string)
#sub hex2bin {   pack('H*',$_[0]) }   ##  hex2bin($hex_string)

sub setcgi
{
#    warn Dumper(@_);
    %cgi = @_;
}

## send error message via BitTorrent protocol
##  bt_error($message)
sub bt_error {
    my $reason =shift||die "no param";
    print STDOUT ${bencode_dict({ 'failure reason' => $reason })};
    return 0; ## Apache::OK, and boolean false
}


## map of event keys to coderefs (subroutines)
use constant BT_EVENTS =>
  {
    'started'	=> \&bt_peer_started,
    'stopped'	=> \&bt_peer_stopped,
    'completed'	=> \&bt_peer_progress,
    ''		=> \&bt_peer_progress
  };



sub convert_ip_ntoa 
{
    my $ip=shift;
    my $peer_addr = inet_ntoa($ip);
    warn "convert_ip_ntoa :" . $ip  . " -> ". $peer_addr;
    return $peer_addr;
}

sub bt_send_peer_list {
    my($torrent) = shift || confess "missing torrent";
    my $numwant = $cgi{'numwant'};
    my $num_peers = $$torrent{'peers'} + $$torrent{'seeds'};

    ## Send an empty peer list upon 'stopped' event because generating a random
    ## peer list is one of the most expensive queries in this program.
    ## (The original (in Python) tracker returns peers even when event==stopped.
    ##  PHPBTTracker chose to send an empty list when event == stopped,
    ##  unless 'tracker' key had also been submitted (user requested feature))
    my $peers = []; ## send empty peer list when stopped
    ## tell bad seed (scc trying to be seed) not to recontact us for a while
    my $reannounce_min = REANNOUNCE_MIN * 6;  ## (and innocuous for 'stopped')

    if ($numwant != 0 && $cgi{'event'} ne 'stopped') {
	$reannounce_min = REANNOUNCE_MIN;
	## (ORDER BY RAND() is typically very expensive.
	##  The following query attempts a different, less random approach.
	##  Then again, some rudimentary benchmarks with ORDER BY RAND() show
	##  impressive speed when used on HEAP tables of moderate size.  More
	##  thorough testing is needed, but might switch this back to an
	##  ORDER BY RAND() query.  But if MySQL RAND() is used, perform
	##    do benchmark(10,RAND());
	##  just after establishing the connection to the database and before
	##  the first SELECT because some contemporary versions of MySQL
	##  (including 3.23.54) are not initially very random.
	##  Reference: http://www.listsearch.com/mysql.lasso?id=286581)
	## (There exists the possibility that one of the random peers retrieved
	##  might be the current peer.  Big deal.)
	## The goal is for a peer to get at least a slightly different set of
	## peers each time it checks in with the tracker.  A random offset into
	## the table, with a subsequent correction (subtraction) for the overlap
	## skew that favors later entries should be more than sufficient.
	my $offset = 0;
	## (should probably restrict $numwant to <= a hard-coded maximum)
	if ($num_peers > $numwant) {
	    $offset = int rand($num_peers - 0.5*$numwant);
	    ($offset -= $numwant/3) < 0 && ($offset = 0);
	    if (defined $cgi{'last'}) {
		my $last = $cgi{'last'};
		if ($offset < $last && $offset > $last - $numwant) {
		   $offset = $last > 0.5*$numwant
		     ? $last - $numwant < 0
			  ? 0
			  : $last - $numwant
		     : $last + $numwant > $num_peers
			  ? $num_peers - $numwant
			  : $last + $numwant
		}
		if ($offset > $last && $offset < $last + $numwant) {
		   $offset = $num_peers - $last > 1.5*$numwant
		     ? $last + $numwant
		     : $last - $numwant < 0
			  ? 0
			  : $last - $numwant;
		}
	    }
	}
	$cgi{'last'} = $offset;
	my $sth = $cgi{'left'} != 0
	    ## peers and scc get those with status 'seed' and status 'peer'
	  ? $dbh->prepare_cached(QSTR->{'pgroup_not_scc'}, ATTR_USE_RESULT)
	    ## seeds get only those with status 'peer'
	  : $dbh->prepare_cached(QSTR->{'pgroup_only_peers'}, ATTR_USE_RESULT);
	$sth->bind_param(2, $offset, {TYPE=>DBI::SQL_INTEGER})
	  && $sth->bind_param(3, $numwant, {TYPE=>DBI::SQL_INTEGER})
	  && $sth->execute($cgi{'info_hash'}, $offset, $numwant)
	  && ($peers = map { convert_ip_ntoa($_) } $sth->fetchall_arrayref({}));
	$sth->err
	  && return bt_error('database error');
    }

    print STDOUT ${bencode_dict({ 'done peers' => $$torrent{'seeds'},
				  'interval' => 86400,
				  'last' => $cgi{'last'} || 0,
				  'min interval' => $reannounce_min,
				  'num peers' => $num_peers,
				  'peers' => $peers })};
}

sub bt_peer_started {
    my $peer = shift || confess "need peer";
    ## (DNS lookup (if DNS name, not IP) can take non-trivial amount of time)
    my $iaddr = Socket::inet_aton($cgi{'ip'})
      || return bt_error('invalid IP address or unresolvable DNS name sent');

    !(scalar keys %$peer) || $$peer{'ip'} eq $iaddr
      ## tolerate duplicate 'started' peer_id if the IPs match, else error.
      ## fall through and replace existing peer (e.g. with possibly new port)
      || return bt_error("Duplicated peer_id or changed IP address/name. ".
			 "Please restart BitTorrent.");

    my $status = !CHECK_PEER || is_peer($iaddr, $cgi{'port'})
      ? $cgi{'left'} != 0
	  ? 'peer'
	  : 'seed'
      : $cgi{'left'} == 0
	  ? return bt_error('unacceptable seed; unable to connect back to you')
	  : 'scc';

    ## insert/update peer in database tables
    $dbh->do(QSTR->{'info_add'}, {}, Socket::inet_aton(Socket::inet_ntoa($iaddr)),
	     @cgi{'port','peer_id','info_hash'}, $status)
      || return bt_error('database error');
    $dbh->do(QSTR->{'data_add'}, {},
	     @cgi{'left','uploaded','downloaded','peer_id'})
      || return bt_error('database error');

    ## update summary table if new entry (ignore errors)
    if (!scalar keys %$peer) {
	my @updates = $status eq 'peer' ? (1,0,0,0,0) : ## (peers+1)
		      $status eq 'scc'  ? (0,0,1,0,0) : ## (scc+1)
					  (0,1,0,0,0);  ## (seeds+1)
	my $sth = $dbh->prepare_cached(QSTR->{'summary_update'}, {});
	$sth->execute(@updates,$cgi{'info_hash'});
    }

    return 1;
}

sub bt_peer_progress {
    ## get peer info
    my $peer = shift || confess "missing peer";
    scalar keys(%$peer)
      || return bt_peer_started($peer); ## create peer if it does not exist
    my $sth;

#    warn "CGI :". Dumper(%cgi);

    ## check for completed peer or scc
    if ($cgi{'left'} == 0 && $$peer{'status'} ne 'seed') {
	if ($$peer{'status'} eq 'peer') {
	    ## change status from peer to seed
	    $dbh->do(QSTR->{'info_peer_to_seed'}, {}, $cgi{'peer_id'})
	      || return bt_error('database error');
	    ## peers-1, seeds+1, done+1 (ignore errors updating summary)
	    $sth = $dbh->prepare_cached(QSTR->{'summary_update'}, {});
	    $sth->execute(-1,1,0,1,0,$cgi{'info_hash'});
	}
	else {
	    $cgi{'event'} = 'stopped';
	    return bt_peer_stopped($peer);
	}
    }

    ## update peer stats
    $sth = $dbh->prepare_cached(QSTR->{'data_update'}, {});
    return $sth->execute(@cgi{'left','uploaded','downloaded','peer_id'})
      || bt_error('database error');
}

sub bt_peer_stopped {
    ## get peer info
    my $peer =  shift || confess "missing peer";;
    scalar keys(%$peer)
      || ($cgi{'left'} == 0 ? return 1 : return bt_error('unknown peer_id'));
	 ## (if none left to download, assume scc that finished previously)
	 ## (scc stats will not be counted if bt_info HEAP table wiped out)

    ## remove from tables
    ## (ignore errors; entry will eventually be timed out and removed)
    $dbh->do(QSTR->{'data_delete'}, {}, $cgi{'peer_id'});
    $dbh->do(QSTR->{'info_delete'}, {}, $cgi{'peer_id'});

    ## Note: all stats in the summary are 'advisory' and can be manipulated by
    ## any client that so wishes to do so.  A rogue downloader can connect with
    ## a fake client and send statistics almost as easily as spoofing a peer_id.

    ## update summary table (ignore errors)
    my $trans = $cgi{'uploaded'} + $cgi{'downloaded'};
    my @updates =
      $$peer{'status'} eq 'seed'
	? (0,-1,0,0)		## (seeds-1)
	: $$peer{'status'} eq 'peer'
	    ? (-1,0,0,0)	## (peers-1)
	    : $cgi{'left'} == 0
		? (0,0,-1,1)	## (scc-1, done+1)
		: (0,0,-1,0);	## (scc-1)
    my $sth = $dbh->prepare_cached(QSTR->{'summary_update'}, {});
    $sth->execute(@updates,$trans,$cgi{'info_hash'});

    return 1;
}

## (scc leechers are ignored in the scrape stats.  If they are desired,
##  add an entry in the summary table and keep those stats up to date.)
## (These queries could be made $dbh->prepare_cached() if requested frequently.)
sub bt_scrape {

    my $r = shift || confess "missing peer";;

    my $sth;
    if (defined($cgi{'info_hash'})) {
	## binary info_hash is 20 chars, hex-encoded is 40 chars; accept either
	my $id = $cgi{'info_hash'};
	my $len = length($id);
	$len == 40 && $id =~ tr/0-9A-Fa-f// == 40
	  ? ($id = pack('H*',$id))  ## (hex2bin)
	  : $len == 20 || return bt_error('Invalid info_hash received.');

	$sth = $dbh->prepare(
	  "SELECT peers AS incomplete, seeds AS complete,".
	  " substr(bt_summary.sha1 || '                    ', 1, 20)  AS sha1, name ".
	  "FROM bt_summary,bt_names ".
	  "WHERE bt_summary.sha1=? AND bt_summary.sha1=bt_names.sha1",
	  ATTR_USE_RESULT);
	$sth->execute($id)
	  || return bt_error('database error');
    }
    else {
	$sth = $dbh->prepare(
	  "SELECT peers AS incomplete, seeds AS complete,".
	  " substr(bt_summary.sha1 || '                    ', 1, 20) AS sha1, name ".
	  "FROM bt_summary,bt_names ".
	  "WHERE bt_summary.sha1=bt_names.sha1", ATTR_USE_RESULT);
	$sth->execute()
	  || return bt_error('database error');
    }
    my $files = $sth->fetchall_arrayref({});
    $sth->err
      && return bt_error('database error');
    map { $_ = { delete($$_{'sha1'}), $_ } } @$files;
    print STDOUT ${bencode_dict({ 'files' => $files })};

    ## Run cleanup if refresh interval has elapsed.
#    check_last_update($r);
}


##
## bencoding
## reference: http://bitconjurer.org/BitTorrent/protocol.html
##
## (after writing the below, I ran across Convert::Bencode on CPAN
##    http://www.cpan.org/authors/id/O/OR/ORCLEV/ )
##



use constant TYPE_STRING	=> 1;
use constant TYPE_NUMBER	=> 2;
use constant TYPE_DICT		=> 3;
use constant TYPE_DICT_LIST	=> 4;
use constant TYPE_STRING_LIST	=> 5;
use constant TYPE_NUMBER_LIST	=> 6;
## (currently no TYPE_LIST_LIST exists)
use constant BENCODING_KEY_TYPES=>
  {
    # tracker query
    'info_hash'		=> TYPE_STRING,
    'peer_id'		=> TYPE_STRING,
    'ip'		=> TYPE_STRING,
    'port'		=> TYPE_NUMBER,
    'uploaded'		=> TYPE_NUMBER,
    'downloaded'	=> TYPE_NUMBER,
    'left'		=> TYPE_NUMBER,
    'event'		=> TYPE_STRING,
    # (undocumented extensions)
    'trackerid'		=> TYPE_STRING,
    'numwant'		=> TYPE_NUMBER,

    # tracker response
    'failure reason'	=> TYPE_STRING,
    'interval'		=> TYPE_NUMBER,
    'peers'		=> TYPE_DICT_LIST,
    # (undocumented extensions)
    'peer id'		=> TYPE_STRING,
    'min interval'	=> TYPE_NUMBER,
    'num peers'		=> TYPE_NUMBER,
    'done peers'	=> TYPE_NUMBER,
    'last'		=> TYPE_NUMBER,
    'tracker id'	=> TYPE_STRING,

    # metainfo file
    'announce'		=> TYPE_STRING,
    'info'		=> TYPE_DICT,
    'name'		=> TYPE_STRING,
    'piece length'	=> TYPE_NUMBER,
    'pieces'		=> TYPE_STRING,
    'length'		=> TYPE_NUMBER,
    'files'		=> TYPE_DICT_LIST,
    'path'		=> TYPE_STRING_LIST,

    # scrape interface
    'complete'		=> TYPE_NUMBER,
    'incomplete'	=> TYPE_NUMBER
  };

## (unknown keys are omitted from encoded dictionary)
## (For slight speed gain, remove the defined() and number checks, but make sure
##  to validate all hash keys and values before passing them to this routine.)
sub bencode_dict {

#    cluck "encoding";
    my $h = shift || return \('');
    my $ret = bencode $h || confess "problem";
    return \$ret;

    # my($k,$t,$v);
    # my $d = 'd';
    # foreach $k (sort keys %$h) {
    # 	$d .= defined($k) ? length($k).':'.$k : '0:';
    # 	if (!defined($t = BENCODING_KEY_TYPES->{$k})) {
    # 	    $v = \$$h{$k};
    # 	    $t = ref($$v) eq 'HASH'
    # 	      ? TYPE_DICT
    # 	      : ref($$v) eq 'ARRAY'
    # 		  ? @{$$v} == 0 || ref($$v[0])
    # 		      ? TYPE_DICT_LIST
    # 		      : $$v[0] =~ /^\d+$/
    # 			  ? TYPE_NUMBER_LIST
    # 			  : TYPE_STRING_LIST
    # 		  : $$v =~ /^\d+$/
    # 		      ? TYPE_NUMBER
    # 		      : TYPE_STRING;
    # 	}
    # 	if ($t == TYPE_STRING) {
    # 	    $d .= defined($$h{$k}) ? length($$h{$k}).':'.$$h{$k} : '0:';
    # 	}
    # 	elsif ($t == TYPE_NUMBER) {
    # 	    $d .= 'i'.($$h{$k}||'0').'e';
    # 	}
    # 	elsif ($t == TYPE_DICT) {
    # 	    $d .= ${bencode_dict($$h{$k})};
    # 	}
    # 	elsif ($t == TYPE_DICT_LIST) {
    # 	    $d .= 'l';
    # 	    $d .= ${bencode_dict($_)} foreach (@{$$h{$k}});
    # 	    $d .= 'e';
    # 	}
    # 	elsif ($t == TYPE_STRING_LIST) {
    # 	    $d .= 'l';
    # 	    $d .= defined($_) ? length($_).':'.$_ : '0:' foreach (@{$$h{$k}});
    # 	    $d .= 'e';
    # 	}
    # 	elsif ($t == TYPE_NUMBER_LIST) {
    # 	    $d .= 'l';
    # 	    $d .= 'i'.($_||'0').'e' foreach (@{$$h{$k}});
    # 	    $d .= 'e';
    # 	}
    # }
    # $d .= 'e';
    # return \$d;
}

sub warnerror
{
    my $arg=shift;
    cluck $arg;
    return;
}

## (Note: $$s, the bencoded string, is modified and destroyed during processing)
## (A few lines of code have been copied around this routine instead of creating
##  four line routines for e.g. bdecode_string and bdecode_number.  My choice.)
## (Numbers should be checked for validity in context of their use, and so 
##  checking validity of bencoded numbers is not done here. i-0e and i03e pass.)


sub bdecode_dict {
    
    my $arg = shift;
    if(!$arg)
    {
	confess "Null arge to bedncode";
    }
    else
    {
#	warn "Check:" . Dumper($arg);
    }
    my $t2= bdecode($arg);
#    warn Dumper($t2);

# $VAR1 = {
#           'info' => {
#                       'length' => '20598911446',
#                       'piece length' => '262144',
#                       'pieces' => '',
#                       'name' => 'earth-20120401130001.osm.bz2'
#                     },
#           'announce-list' => [
#                                [
#                                  'http://tracker.ccc.de/announce'
#                                ],
#                                [
#                                  'http://tracker.openbittorrent.com/announce'
#                                ],
#                                [
#                                  'http://tracker.publicbt.com/announce'
#                                ],
#                                [
#                                  'http://tracker.istole.it/announce'
#                                ]
#                              ],
#           'announce' => 'http://tracker.ccc.de/announce',
#           'creation date' => '1342878133',
#           'created by' => 'mktorrent 1.0'
#         };


    return $t2;
}


##
## check peer for reachability
##

BEGIN {
  ## Force autoloading of routines that create these constants
  ## (leads to more shared memory in mod_perl)
  no warnings;
  Fcntl::F_GETFL();
  Fcntl::F_SETFL();
  Fcntl::O_NONBLOCK();
  Socket::SO_ERROR();
  Socket::SOCK_STREAM();
  Socket::SOL_SOCKET();
  Socket::INADDR_ANY();
  Socket::IPPROTO_TCP();
  Socket::MSG_DONTWAIT();
  Socket::MSG_NOSIGNAL();
  Socket::PF_INET();
}

use constant PROTOCOL_NAME     => 'BitTorrent protocol';
use constant PROTOCOL_NAME_LEN => length(PROTOCOL_NAME);

sub is_peer {

## $iaddr must be packed address, i.e. inet_aton($ip)
    my $iaddr=shift || confess "missing packed address";
    my $port =shift ||  confess "missing port"; 

    CHECK_PEER || return 1; ## assume reachable if CHECK_PEER is disabled

    my($flags,$rpackedaddr,$data);
    my $SH = Symbol::gensym;
    my $bitvec = '';

    ## (The following code is taken from a general purpose library of mine
    ##  and is special-purposed here.  The code here is not as error-tolerant
    ##  and reports failure on some anomalies handled by the robust library.)

    ## create socket and configure (return 'pass' on errors in this section)
    ## set nonblocking mode (else connect() will block)
    ## set unbuffered mode (disable stdio buffering of output), set bitvec
    socket($SH, Socket::PF_INET, Socket::SOCK_STREAM, Socket::IPPROTO_TCP)
      && ($flags = fcntl($SH, Fcntl::F_GETFL, 0))
      && fcntl($SH, Fcntl::F_SETFL, $flags | Fcntl::O_NONBLOCK)
      || return 1;
    select((select($SH),$|=1)[0]);
    vec($bitvec,fileno $SH,1) = 1;

    ## connect to remote address and port
    ## 'man 2 connect' for nonblocking methodology with EINPROGRESS
    ## timeout after 5 seconds (modify time in select() below to change this)

    warn "Going to try and connect to port :$port and iaddr:$iaddr\n" if $debug;
    my $x=Socket::sockaddr_in($port, $iaddr);
    warn "Got socket: $x" if $debug;
    connect($SH, $x)
      || $! == Errno::EINPROGRESS
      || return 0;
    select(undef,my $w=$bitvec,undef,5) > 0
      || ($! = Errno::ETIMEDOUT, return 0);
    ($! = unpack('I',getsockopt($SH,Socket::SOL_SOCKET,Socket::SO_ERROR))) == 0
      || return 0;

    ## send
    ## entire sent string is short and should easily fit in socket send buffers
    ## (SO_SNDBUF) so, for simplicity, fail if this is not the case
    ##   protocol send
    ##    1 byte containing length of protocol name followed by protocol name
    ##    8 bytes reserved
    ##   20 bytes binary data $info_hash
    send($SH, chr(PROTOCOL_NAME_LEN).PROTOCOL_NAME.
	      "\0\0\0\0\0\0\0\0".$cgi{'info_hash'},
	 Socket::MSG_DONTWAIT|Socket::MSG_NOSIGNAL)==1+(PROTOCOL_NAME_LEN)+8+20
      || (shutdown($SH,2), return 0);
    ## recv
    ## entire expected string is short and should easily fit in sender's socket
    ## send buffers and our socket recv buffers (SO_RCVBUF) so, for simplicity,
    ## fail if not received all at once, after waiting for data to be ready
    ##   protocol receive
    ##    1 byte containing length of protocol name followed by protocol name
    ##    8 bytes reserved (ignore its contents)
    ##   20 bytes binary data $info_hash
    ##   20 bytes binary data $peer_id
    select(my $r=$bitvec,undef,undef,5) > 0
      || (shutdown($SH,2), $! = Errno::ETIMEDOUT, return 0);
    defined(recv($SH, $data, 1+PROTOCOL_NAME_LEN+8+20+20, Socket::MSG_NOSIGNAL))
      || (shutdown($SH,2), return 0);
    shutdown($SH,2);
    close($SH);

    ## validate response
    return  ord(substr($data,0,1)) == PROTOCOL_NAME_LEN
	    && substr($data,1,PROTOCOL_NAME_LEN) eq PROTOCOL_NAME
	    && substr($data,1+PROTOCOL_NAME_LEN+8,20) eq $cgi{'info_hash'}
	    && substr($data,1+PROTOCOL_NAME_LEN+8+20,20) eq $cgi{'peer_id'};
}

## Clean timed out entries from the peer/scc hash tables
## (takes optional _quoted_ hash as second param for extensible use by scrape)
##
## Obtain a mutex before locking table because LOCK TABLE is blocking and we
## only desire for the first routine to obtain the lock to run the cleanup.
## (Be certain to release the GET_LOCK mutex and to UNLOCK TABLES before
##  returning from this routine)
##
## The goal of this routine is aimed at simple, automatic maintenance of tables.
## While it would be nice to set this whole routine up as a transaction and to
## rollback on any failure, HEAP and MyISAM tables do not support transactions,
## and the data within these tables can be regenerated from web server log files
## Also, it uses large hashes fairly freely, so it may be a bit greedy with
## memory on sites that have hundreds of torrents.  In that case, remove it from
## the mainline code and run it separately as a cron job.
##
##  refresh_summary($r->request_time)

sub Connect
{
    if (!$dbh) {
	$dbh = DBI->connect(@{(BT_DB_INFO)})
	    || die 'Database error.';
    }
    die "No database" unless $dbh;
    return $dbh;
}

sub refresh_summary {
    my $now = shift || confess "missing now param";

    ## Obtain mutex, double-check that tables not recently refreshed,
    ## and then lock bt_summary table (return if any error).  Following that,
    ## sleep arbitrarily 1 second to allow events in progress time to complete.
    ## All new requests will block on the bt_summary table since that is the
    ## first request made in handler().  After sleeping, lock other tables.
    ## (The Perl package global is not shared between different Apache child
    ##  processes, so check a table in the database for the actual time mark.)
    ## (RaiseError MUST NOT be set in the database driver attribute, or else
    ##  this code might abort before unlocking tables and releasing the mutex!)
#   $dbh->selectrow_array("SELECT GET_LOCK('bt_tracker', 0)")      || return;
    Connect();
    my $mark = $dbh->selectrow_array("SELECT mark FROM bt_mark WHERE rowid=0")
      || 0;
    die unless $mark;
    die unless $now;
    
    if (
	! 
	(($mark < ($now - REFRESH_INTERVAL)
	 || (@ARGV && $ARGV[0] eq 'force-refresh')))
	)
    {
	warn "problem";
	return;
    }

#     && $dbh->do("LOCK TABLES bt_summary WRITE")
#     || ($dbh->do("DO RELEASE_LOCK('bt_tracker')"), return);
    select(undef,undef,undef,1);
#   $dbh->do("LOCK TABLES bt_summary WRITE, bt_mark WRITE,".
#	     " bt_data WRITE, bt_info WRITE, bt_names READ")
#     || ($dbh->do("UNLOCK TABLES"),
#	  $dbh->do("DO RELEASE_LOCK('bt_tracker')"), return);

    $BitTorrent::TrackerCGI::mark = $now;

    ## (statistics can be regenerated from web logs; ignore errors)
    my $curr = $dbh->selectall_hashref(
      "SELECT trans,done,otrans,odone,".
      " substr(bt_summary.sha1 || '                    ', 1, 20) as sha1,size,mark,name ".
      "FROM bt_summary,bt_names WHERE bt_summary.sha1=bt_names.sha1",
      'sha1', ATTR_USE_RESULT) || +{};

    my $expired = $now - TIMEOUT_INTERVAL;
    my $deleted_sums = $dbh->selectall_hashref(
      "SELECT substr(sha1 || '                    ', 1, 20) AS sha1, COUNT(*) AS count,".
      " SUM(upld+dnld) AS trans ".
      "FROM bt_data,bt_info WHERE bt_data.peer_id=bt_info.peer_id".
      " AND mark < datetime($expired, 'unixepoch', 'localtime') GROUP BY sha1",
      'sha1', ATTR_USE_RESULT) || +{};

    my($sth,$k,$v,$d,$t);

    ## run cleanups (ignore errors)
    ## (suboptimal; could return peer_id's above and loop over those rather
    ##  than performing an additional full table scan.  Table sizes will not
    ##  be more than a few thousand rows except on the largest of sites, so
    ##  it really does not matter much.)
    ## (there is an minor theoretical race condition between the above and this
    ##  query whereby stats may be lost if a peer times out between the queries)
    if (%$deleted_sums) {
	$dbh->do("DELETE FROM bt_data WHERE mark < datetime($expired, 'unixepoch', 'localtime')")
	    if (scalar keys %$deleted_sums);
	$sth = $dbh->prepare("DELETE FROM bt_info WHERE sha1=?");
	$sth->execute($_) foreach (keys %$deleted_sums);
    }

    ## get new peer and seed counts (ignore errors)
    ## (since db tables already locked, use mysql_use_result method since
    ##  it is slightly faster and we can not block more than we already are)
    $sth = $dbh->prepare(
      "SELECT substr(sha1 || '                    ', 1, 20),status,COUNT(status),SUM(pend),SUM(upld+dnld) ".
      "FROM bt_info,bt_data WHERE bt_info.peer_id=bt_data.peer_id ".
      "GROUP BY sha1,status", ATTR_USE_RESULT);
    $sth->execute();
    while (($v = $sth->fetchrow_arrayref())) {
	$k = $$curr{$$v[0]};	       ## look up sha1 in %$curr
	$$k{$$v[1]} = $$v[2];	       ## set status key [peer|seed|scc] = count
	($$k{'pend'} ||= 0) += $$v[3]; ## sum remaining to be downloaded
	($$k{'live'} ||= 0) += $$v[4]; ## sum of partial downloads
    }

    ## update summary table (ignore errors)
    ## (intentionally update all sha1's (keys %$curr) and
    ##  not just those with removed entries (keys %$deleted_sums)
    $sth = $dbh->prepare(
      "UPDATE bt_summary SET peers=?,seeds=?,scc=?,trans=?,".
      " otrans=?,odone=done WHERE sha1=?");
    while (($k,$v) = each %$curr) {
	## (merge values from %$counts into %$curr (used later for stats))
	$$v{'scc'}  ||= 0;
	$$v{'peer'} ||= 0;
	$$v{'seed'} ||= 0;
	$d = $$deleted_sums{$k} || {};
	## update summary table with current stats
	$t = $$v{'trans'} += $$d{'trans'} || 0;
	$$v{'trans'} += $$v{'live'} || 0;
	$sth->execute($$v{'peer'}, $$v{'seed'}, $$v{'scc'},
		      $t, $$v{'trans'}, $k);
	## transfer_over_period/(#downloaders_over_period * period_length)
	$t = ($$v{'done'} - $$v{'odone'} + ($$d{'counts'} || 0)
	      + $$v{'peer'} + $$v{'seed'} + $$v{'scc'}) || 1; # no divide by 0
	$$v{'avg_rate'} = ($$v{'trans'} - $$v{'otrans'}) / ($t*($now - $mark));
	## 1 - (remaining size for curr downloaders)/(#downloaders * total_size)
	$t = ($$v{'pend'} || 0) / ((($$v{'peer'}+$$v{'scc'})||1) * $$v{'size'});
	$$v{'avg_progress'} = $t ? 1 - $t : 0; ## 0% rather than 100% if $t == 0
    }

    ## update mark, unlock tables, and release mutex
    $dbh->do("INSERT OR REPLACE INTO bt_mark (mark, rowid) values('$now',0)");
#   $dbh->do("UNLOCK TABLES");
#   $dbh->do("DO RELEASE_LOCK('bt_tracker')");

    ## synchronize summary and name table entries with entries in torrent dir
    scan_torrent_dir($curr, $now);

    ## print statistics out to in HTML table
    print_stats($curr, $now);
}

##
## torrent setup
##

## synchronize summary and name table entries with entries in torrent dir
## (insert and delete)  If torrents are removed from summary table, all new
## requests will fail with an error message along the lines of
##   'Requested torrent not available on this tracker.'
## and any updates in progress will silently fail (since errors updating the
## summary table are ignored throughout the code).  Eventually, entries in
## bt_info and bt_data will expire and be removed by the code above.
## No locks are held during these operations since any inserts or deletes
## will be of the same data, and errors are ignored.
##
## (not the prettiest, most efficient code; written quickly as proof-of-concept)
sub scan_torrent_dir {
    ## (empty %$counts will cause attempt to reinsert all torrents in dir)
    my($counts,$now) = @_;
    my %torrents;
    $torrents{$_} = undef foreach (keys %$counts);
    ## (originally, did my %torrents = %$counts; to copy keys and hashref, but
    ##  then the delete() below on %torrents was throwing away the
    ##  'torrent_path' added to %$counts.  Perl bug?  hopefully fixed in later
    ##  versions; should check.  Even though the same key in both hashes refers
    ##  to the same hashref, removing the key and hashref from one hash should
    ##  not mask the value added to the hashref in this routine.  Other values
    ##  already within the hashref remain.  Only 'torrent_path' is discarded)

    my $sth_summary_del=$dbh->prepare("DELETE FROM bt_summary WHERE sha1=?");
    my $sth_names_del=$dbh->prepare("DELETE FROM bt_names WHERE sha1=?");
    my $sth_summary_ins=$dbh->prepare("INSERT INTO bt_summary (sha1) values (?)");
    my $sth_names_ins=$dbh->prepare("INSERT INTO bt_names (size,mark, sha1,name) ".
				    "values (?,?,?,?)");
    my $sth_info_sel=$dbh->prepare("SELECT substr(peer_id || '                    ', 1, 20) FROM bt_info ".
				   "WHERE sha1=?");
    my $sth_info_del=$dbh->prepare("DELETE FROM bt_info WHERE sha1=?");
    my $sth_data_del=$dbh->prepare("DELETE FROM bt_data WHERE peer_id=?");

    ## loop down through directory reading torrent files

    local @params = (\%torrents,$counts,$now,$sth_summary_ins,$sth_names_ins);
    File::Find::find({ 'wanted' => \&process_torrent_files,
		       'follow_fast' => 1, 'no_chdir' => 1 },
		     TORRENT_PATH);

    ## delete entries from db for remaining keys in %torrents not found in dir
    my($sha1,$c);
    foreach $sha1 (keys %torrents) {
	$c = delete $$counts{$sha1};
	warn("deleted sha1=".unpack('H*',$sha1).  ## (bin2hex)
	     " done=$$c{'done'} trans=$$c{'trans'} peers=$$c{'peer'} ".
	     "seeds=$$c{'seed'} scc=$$c{'scc'}\n");
	## (cascade_on_delete would have been nicer)
	## (MySQL also does not support multi-table delete until v4.0.0)
	$sth_summary_del->execute($sha1);
	$sth_names_del->execute($sha1);
	$sth_info_sel->execute($sha1);
	$sth_data_del->execute($_) foreach ($sth_info_sel->fetchrow_array());
	$sth_info_del->execute($sha1);
    }
}


sub process_torrent_files {

    # this is called from File::Find 
    my $path = $_;
    my $name =$File::Find::name;
    my $relative_path;
    if (-f $path)
    {
	if ($name =~ m/\Q@{[(TORRENT_PATH)]}\E(.+)/o) {
	    $relative_path = $1;
	}
	else {
	    warn "bad filename $name";
	    return;
	}
    }
    elsif (-l $path)
    {
	warn "$path is a link";
	return;
    }
    
    my $metainfo = read_torrent_file($name);
    if (!$metainfo) {
	print STDERR "$name cannot be read\n";
	return; ## (torrents that become unreadable will be deleted from db!)
    }
    if (! $$metainfo{'announce'} eq TRACKER_URL )
    {
	print STDERR 
	    "$name does not announce this tracker (". 
	    TRACKER_URL.
	    " NE " . 
	    $$metainfo{'announce'} .  
	    ")\n";
	return;
    }
    #info hash: SHA1 hash of the "info" section of the metainfo (*.torrent)
    my $sha1 = Digest::SHA1::sha1(${bencode_dict($$metainfo{'info'})});
    my($torrents,$counts) = @params[0,1];
    if (exists $$torrents{$sha1}) {
	delete $$torrents{$sha1};
    }
    else {
	my($now,$sth_summary_ins,$sth_names_ins) = @params[2,3,4];
	my $size;
	if (!defined($size = $$metainfo{'info'}->{'length'})) {
	    $size = 0;
	    map { $size += $_->{'length'} } @{$$metainfo{'info'}->{'files'}};
	}
	$$metainfo{'info'}->{'name'} ||=
	  length($relative_path) <= 92 ? $relative_path : '';

	confess "missing sth_summary_ins" unless $sth_summary_ins;
#	warn Dumper($sth_summary_ins);
	warn "going to add $sha1";
	$sth_summary_ins->execute($sha1);


	$sth_names_ins->execute($size,$now,$sha1,$$metainfo{'info'}->{'name'});
	@{$$metainfo{'info'}}{'sha1','size','avg_rate','avg_progress'} =
	  ($sha1,$size,0,0);
	$$counts{$sha1} = $$metainfo{'info'};
	$$counts{$sha1}->{'mark'} = $now;
    }
    $$counts{$sha1}->{'torrent_path'} = $relative_path;
}

## read in torrent file
## do some simple (not exhaustive) checks that it is indeed a torrent file
## If users are allowed to create directories, there is a race on symlinks of
## directories.  However, the resulting file still needs to be in bencoded
## format, and it is highly unlikely that non-torrent files will be in this
## format.
sub read_torrent_file {
    my $torrent_path  = shift || confess "missing torrent path";
    my $FH = Symbol::gensym;
    my($size,$torrent,$info);
    local $/;
    
#    warn "check name: \"$torrent_path\"\n";

    if ($torrent_path !~ m/\.torrent$/) {
	warn " wrong name \"$torrent_path\" ";
	return;
    }

#    if ($torrent_path !~ m%^\.{1,2}/|/\.{1,2}/|/\.{1,2}$|\0%) 
#    {
#	warn " wrong name2 $torrent_path ";
#	return ;
#    }

    open($FH,'<'.$torrent_path) or return warn "cannot open $torrent_path";
    binmode($FH,':raw') or die;
    $size = (stat($FH))[7];
    return unless (-f $_);
#    return warn "too big" unless $size < 524288;  ## (512 kB)
    return warn "error1" unless  ($/ = \$size);
    if (!($torrent = bdecode_dict(<$FH>))) 
    {
	warn "error on bdecode_dict for FH $torrent_path";
	return ;
    }
    return warn "error3" unless $$torrent{'announce'} ne '';
    return warn "error4" unless  ($info = $$torrent{'info'});
    return warn "error5" unless defined($$info{'piece length'});
    return warn "error6" unless  defined($$info{'pieces'});
    return warn "error7" unless (defined($$info{'length'}) ^ defined($$info{'files'}));
    close($FH) or die;

    defined($$info{'name'})
	? length($$info{'name'}) <= 92 || return warn "error"
	: ($$info{'name'} = '');

    return $torrent;
}

## simple html_encode in-place over arg
sub html_encode_in_place {
    my $html = shift || confess "missing html";

    $html=~s/&/&amp;/g;
    $html=~s/</&lt;/g;
    $html=~s/>/&gt;/g;
    $html=~s/"/&quot;/g;
}

## [what ugliness!  written quickly as proof-of-concept before release.]
## To qualify the relative links, use a <base href> tag in doc that includes us.
sub print_stats {
    my($stats,$now) = @_;
    my($FH,$RSS) = (Symbol::gensym, Symbol::gensym);
    open($FH,  '+<'.TORRENT_STATS_FILE) || return;
    open($RSS, '+<'.TORRENT_RSS_FILE)   || return;
    truncate($FH,0);
    truncate($RSS,0);

    print $RSS "  <generator>BitTorrent::TrackerCGI (v",
	       $BitTorrent::TrackerCGI::VERSION,")</generator>\n";

    print $FH <<"TORRENT_STATS";
<style>
  td.gray1
  {background-color: rgb(90%,90%,90%); white-space: nowrap; text-align: right;}
  td.gray2
  {background-color: rgb(95%,95%,95%); white-space: nowrap; text-align: right;}
</style>
<table>
<tr>
<th>current<br>avg. rate</th>
<th>average<br>progress</th>
<th>#<br>seeds</th>
<th>#<br>peers</th>
<th>#<br>scc</th>
<th>total<br>transfer</th>
<th>time<br>elapsed</th>
<th>#<br>done</th>
<th>torrent<br>size</th>
<th>&nbsp;&nbsp;&nbsp;</th>
<th align=left>torrent<br>name</th>
</tr>
TORRENT_STATS

    my $most_recent = 0;
    my($c,$path,$nfo,$size,$trans,$time,$rate,$progress);
    foreach (sort
	     { $$stats{$a}->{'torrent_path'} cmp $$stats{$b}->{'torrent_path'} }
	     keys %$stats) {
	$c = $$stats{$_};
	$path = $$c{'torrent_path'};
	($nfo = $path) =~ s/\.torrent$//;
	$nfo  = (-e TORRENT_PATH.$nfo.'.html') ? $nfo.'.html' :
		(-e TORRENT_PATH.$nfo.'.txt')  ? $nfo.'.txt'  :
		(-e TORRENT_PATH.$nfo.'.nfo')  ? $nfo.'.nfo'  : '';
	html_encode_in_place($nfo);
	$nfo = qq{<a href="$nfo">}.INFO_IMG.'</a>' if ($nfo ne '');
	$$c{'name'} || (($$c{'name'}) = $path =~ m|([^/]+)$|);
	html_encode_in_place($path);
	html_encode_in_place($$c{'name'});
	$size = $$c{'size'} ||= 0;
	$size =
	  ($size < 1024)
	    ? sprintf('%01.2f &nbsp;&nbsp;B', $size) :
	  ($size < 1048576)
	    ? sprintf('%.2f KiB', $size/1024) :
	  ($size < 1073741824)
	    ? sprintf('%.2f MiB', $size/1048576) :
	  ($size < 1099511627776)
	    ? sprintf('%.2f GiB', $size/1073741824)
	    : sprintf('%.2f TiB', $size/1099511627776);
	$$c{'seed'} ||= 0;
	$$c{'peer'} ||= 0;
	$$c{'scc'}   ||= 0;
	$$c{'done'}  ||= 0;
	$trans = $$c{'trans'} || 0;
	$trans =
	  ($trans < 1024)
	    ? sprintf('%01.3f &nbsp;&nbsp;B', $trans) :
	  ($trans < 1048576)
	    ? sprintf('%.3f KiB', $trans/1024) :
	  ($trans < 1073741824)
	    ? sprintf('%.3f MiB', $trans/1048576) :
	  ($trans < 1099511627776)
	    ? sprintf('%.3f GiB', $trans/1073741824)
	    : sprintf('%.3f TiB', $trans/1099511627776);
	$time = $now - ($$c{'mark'}||0);
	$time = sprintf('%02dd%02dh%02dm', int($time/86400),
			int($time%86400/3600), int($time%3600/60));
	$$c{'avg_rate'} ||= 0;
	$rate =
	  ($$c{'avg_rate'} < 1024)
	    ? sprintf('%01.2f &nbsp;&nbsp;B/s', $$c{'avg_rate'}) :
	  ($$c{'avg_rate'} < 1048576)
	    ? sprintf('%.2f KiB/s', $$c{'avg_rate'}/1024) :
	  ($$c{'avg_rate'} < 1073741824)
	    ? sprintf('%.2f MiB/s', $$c{'avg_rate'}/1048576) :
	  ($$c{'avg_rate'} < 1099511627776)
	    ? sprintf('%.2f GiB/s', $$c{'avg_rate'}/1073741824)
	    : sprintf('%.2f TiB/s', $$c{'avg_rate'}/1099511627776);
	$progress = sprintf('%01.2f', ($$c{'avg_progress'}||0) * 100);

	print $FH <<"TORRENT_STATS";
<tr>
<td class=gray1>&nbsp;$rate</td>
<td class=gray2>&nbsp;$progress %</td>
<td class=gray1>&nbsp;$$c{'seed'}</td>
<td class=gray2>&nbsp;$$c{'peer'}</td>
<td class=gray1>&nbsp;$$c{'scc'}</td>
<td class=gray2>&nbsp;$trans</td>
<td class=gray1>&nbsp;$time&nbsp;</td>
<td class=gray2>&nbsp;$$c{'done'}</td>
<td class=gray1>&nbsp;$size&nbsp;</td>
<td class=gray2>$nfo</td>
<td class=gray1 style="text-align: left">&nbsp;<a href="$path">$$c{'name'}</a>
</td>
</tr>
TORRENT_STATS

	$$c{'mark'} < $most_recent || ($most_recent = $$c{'mark'});
	$time = RFC_2822_date($$c{'mark'});

	print $RSS <<"        TORRENT_RSS";

  <item>
    <title>$$c{'name'}</title>
    <pubDate>$time</pubDate>
    <enclosure
      url="@{[(TORRENT_BASE_URL)]}/$path"
      type="application/x-bittorrent"
      length="$$c{'size'}"
    />
  </item>
        TORRENT_RSS

    }

    print $FH "</table>\n",
	      '<font size="-1"><br>(refreshed from database every ',
	      int(REFRESH_INTERVAL/60)," minutes)</font><br>\n";
    close $FH;

    print $RSS "\n  <lastBuildDate>",RFC_2822_date($most_recent),
	       '</lastBuildDate>' if ($most_recent);

    close $RSS;
}

## (modified from my not-yet-released SMTP library Perl tools)
## Summary:
##   creates RFC-2822 date string
## Returns:
##   string containing RFC 2822 compliant date
## Notes:
##   Is nearly equivalent to `date --rfc-822` (if no time param given)
##   String returned is _NOT_ CRLF terminated.  Caller must terminate line.
##   If passed a unix time (seconds), it will use that time to generate date.
##     This allows the passing of $^T if it is known to be valid (such as in
##     a CGI program or in a mod_perl instance where it is updated at the start
##     of each script (not done by default))
##   localtime(0) is calculated every time for accuracy w/ long running programs
##
## ** might be a possible bug when times cross daylight savings time boundary
##    (would result in inaccuracy of one hour)
##    (not a big deal for usage in this program)
sub RFC_2822_date {

    my $time = shift || confess "missing time";

    my($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)
      = localtime( defined $time ? $time : time );
    my($tz_min,$tz_hour) = (localtime 0)[1,2];
    my $tz_prefix;
    ($tz_hour += $isdst) <= 12
      ? ( $tz_prefix = '+' )
      : ( $tz_prefix = '-',
          $tz_hour = 24 - $tz_hour, 
          $tz_min && ($tz_min = 60 - $tz_min) );
    return sprintf '%s, %02d %s %4d %02d:%02d:%02d %s%02d%02d',
		(qw(Sun Mon Tue Wed Thu Fri Sat))[$wday], $mday,
		(qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec))[$mon],
		$year+1900, $hour, $min, $sec, $tz_prefix, $tz_hour, $tz_min;
}

## Under mod_perl, %cgi = $r->args was corrupting keys if they contained %00.
## This routine does not have such a problem.  For non-mod_perl, these 13 lines
## of code avoid the need to pull in bloated CGI.pm.  K.I.S.S.: intentionally
## do not handle multi-values; later keys with same name overwrite earlier.
sub parse_query_string {
    my $input = shift||'';
    my $cgi = \%cgi;#shift || {};
    my($k,$v);
#    my $cgi   = $_[1] || {};		# get user-provided %$cgi (if passed)
#    defined($query)?$query:'';# copy query string because we modify it
    $input =~ s/%(?![\dA-F]{2})//gi;	# remove improperly encoded percents (%)
    $input =~ tr/+/ /;			# decode '+' into spaces in query string
    foreach (split '&',$input) {	# resolve and unencode vars into %$cgi
	($k,$v) = split '=',$_,2;
	$k =~ s/%([\dA-F]{2})/chr(hex $1)/egi;
	$v =~ s/%([\dA-F]{2})/chr(hex $1)/egi;
	$$cgi{$k} = $v;
    }
    warn "Got cgi:". Dumper(\%cgi);
    return $cgi;
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

sub DropTables {

    Connect();
    $dbh->do(qq{ drop TABLE if exists bt_names  }) || die('Database error: '.$dbh->errstr."\n");
    $dbh->do(qq{ drop TABLE if exists bt_summary    }) || die('Database error: '.$dbh->errstr."\n");
    $dbh->do(qq{ drop TABLE if exists bt_data    }) || die('Database error: '.$dbh->errstr."\n");
    $dbh->do(qq{ drop TABLE if exists bt_info    }) || die('Database error: '.$dbh->errstr."\n");
    $dbh->do(qq{ drop INDEX if exists stat_idx    }) || die('Database error: '.$dbh->errstr."\n");
    $dbh->do(qq{ drop TABLE if exists bt_mark    }) || die('Database error: '.$dbh->errstr."\n");

}


sub CreateTables
{
    Connect();

    $dbh->do(qq{
CREATE TABLE IF NOT EXISTS bt_names
(
 size       BIGINT UNSIGNED DEFAULT '0' NOT NULL,
 mark       BIGINT UNSIGNED DEFAULT '0' NOT NULL,
 sha1     CHAR(20) PRIMARY KEY   NOT NULL,
 name  VARCHAR(92) DEFAULT ''           NOT NULL
)
	     }) || die('Database error: '.$dbh->errstr."\n");

    $dbh->do(qq{
    CREATE TABLE IF NOT EXISTS bt_summary
    (
     peers     INT UNSIGNED DEFAULT '0' NOT NULL,
     seeds     INT UNSIGNED DEFAULT '0' NOT NULL,
     scc       INT UNSIGNED DEFAULT '0' NOT NULL,
     done      INT UNSIGNED DEFAULT '0' NOT NULL,
     trans  BIGINT UNSIGNED DEFAULT '0' NOT NULL,
     otrans BIGINT UNSIGNED DEFAULT '0' NOT NULL,
     odone     INT UNSIGNED DEFAULT '0' NOT NULL,
     sha1 BLOB(20) PRIMARY KEY   NOT NULL
    )
    }) || die('Database error: '.$dbh->errstr."\n");

    $dbh->do(qq{
    CREATE TABLE IF NOT EXISTS bt_data
    ( 
      pend        BIGINT UNSIGNED DEFAULT '0' NOT NULL,
      upld        BIGINT UNSIGNED DEFAULT '0' NOT NULL,
      dnld        BIGINT UNSIGNED DEFAULT '0' NOT NULL,
      mark TIMESTAMP(14),
      peer_id   BLOB(20) PRIMARY KEY   NOT NULL
    ) 
    }) || die('Database error: '.$dbh->errstr."\n");

    $dbh->do(qq{
    CREATE TABLE IF NOT EXISTS bt_info
    (
     ip          BIGINT UNSIGNED DEFAULT '0' NOT NULL,
     port      SMALLINT UNSIGNED DEFAULT '0' NOT NULL,
     peer_id   BLOB(20) PRIMARY KEY   NOT NULL,
     sha1      BLOB(20)               NOT NULL,
     status    CHAR(4) default 'peer' NOT NULL
    ) 
    }) || die('Database error: '.$dbh->errstr."\n");


    $dbh->do(qq{
    CREATE INDEX IF NOT EXISTS  stat_idx ON bt_info(sha1,status)    
    }) || die('Database error: '.$dbh->errstr."\n");

#INDEX     stat_idx (sha1,status)


## The bt_mark contains the timestamp 
    $dbh->do(qq{
    CREATE TABLE IF NOT EXISTS bt_mark
    (
     mark      BIGINT UNSIGNED DEFAULT '0' NOT NULL,
     rowid        INT UNSIGNED DEFAULT '0' NOT NULL UNIQUE
    ) 
    }) || die('Database error: '.$dbh->errstr."\n");

}

## MAX_ROWS is used in database table creation
## (must 'alter table' after tables created; changing this will have no effect)
## Note: MAX_ROWS is only advisory to MySQL to help it choose pointers sizes
sub Main 
{
    if ($ARGV[0] eq 'force-refresh') {
    print "Content-type: text/plain; charset=ISO-8859-1\n\n"	if (exists $::ENV{'GATEWAY_INTERFACE'});

    Connect();

    refresh_summary($^T);
    print "\ndone\n\n";
}
elsif ($ARGV[0] eq 'refresh') {
    print "Content-type: text/plain; charset=ISO-8859-1\n\n"
      if (exists $::ENV{'GATEWAY_INTERFACE'});

	exit(1);
    }

    ## database (BT_DB_NAME) must already have been created in advance, just
    ## like db user (BT_DB_USER) and db password (BT_DB_PASS)
    ## (If you change the size of bt_names.name VARCHAR(92), you must change
    ##  the places in the file that hard-code this length; just search for "92")

    CreateTables;

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
http://www.perlmonks.org/?node_id=817899
http://www.sqlite.org/datatype3.html
