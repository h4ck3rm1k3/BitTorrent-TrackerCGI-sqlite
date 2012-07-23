use lib "/home/mdupont/experiments/fosm/tracker/BitTorrent-TrackerCGI-sqlite/lib";
use BitTorrent::Tracker;


my $r = {};
{
    package apache_connection_rec_hack;
    sub remote_ip { $::ENV{'REMOTE_ADDR'} || '' }
    
    package apache_request_rec_hack;
    sub connection { bless({}, 'apache_connection_rec_hack') }
    sub headers_out { print "$_[1]: $_[2]\n" }
    sub no_cache { print 
		       "Cache-Control: no-cache, max-age=0, must-revalidate\n",
		       "Pragma: no-cache\n",
		       "Expires: 0\n",
		       "Vary: *\n" }
    sub path_info { $::ENV{'PATH_INFO'} }
    sub request_time { $^T }
    sub rflush { select((select(STDOUT),$|=1)[0]) }
    sub send_http_header { print "Content-type: $_[1]\n\n" }
    sub status { print "Status: $_[1]\n" unless ($_[1] == 200) }
    bless $r;
}

#bhandler($r) unless $^C;


refresh_summary 
