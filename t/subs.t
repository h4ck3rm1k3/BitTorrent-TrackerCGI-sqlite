use lib "/home/mdupont/experiments/fosm/tracker/BitTorrent-TrackerCGI-sqlite/lib";
use BitTorrent::TrackerCore;
use Data::Dumper;

#bhandler($r) unless $^C;

BitTorrent::TrackerCore::RFC_2822_date ($^T);

warn "Encode:". Dumper(BitTorrent::TrackerCore::bencode_dict (
			   'info' => 1 
			   
		       ));


warn "Encode:". Dumper(BitTorrent::TrackerCore::bencode_dict (
			   'info' => {
			       'length' => '20598911446',
			       'piece length' => '262144',
			       'pieces' => '',
			       'name' => 'earth-20120401130001.osm.bz2'
			   }
			   
		       ));


warn "Encode:". Dumper(BitTorrent::TrackerCore::bencode_dict (
			  { 
			      'info' => {
			       'length' => '20598911446',
			       'piece length' => '262144',
			       'pieces' => '',
			       'name' => 'earth-20120401130001.osm.bz2'
			      }
			  }			 
		       ));

warn "Encode:". Dumper(BitTorrent::TrackerCore::bencode_dict (

			   [
			    [
			     'http://tracker.ccc.de/announce'
			    ],
			    [
			     'http://tracker.openbittorrent.com/announce'
			    ],
			    [
			     'http://tracker.publicbt.com/announce'
			    ],
			    [
			     'http://tracker.istole.it/announce'
			    ]
			   ]
		       ));


warn "Encode:". Dumper(BitTorrent::TrackerCore::bencode_dict (
{
           'info' => {
                       'length' => '20598911446',
                       'piece length' => '262144',
                       'pieces' => '',
                       'name' => 'earth-20120401130001.osm.bz2'
                     },
           'announce-list' => [
                                [
                                  'http://tracker.ccc.de/announce'
                                ],
                                [
                                  'http://tracker.openbittorrent.com/announce'
                                ],
                                [
                                  'http://tracker.publicbt.com/announce'
                                ],
                                [
                                  'http://tracker.istole.it/announce'
                                ]
                              ],
           'announce' => 'http://tracker.ccc.de/announce',
           'creation date' => '1342878133',
           'created by' => 'mktorrent 1.0'
         }
));

BitTorrent::TrackerCore::bdecode_dict ("d8:announce30:http://tracker.ccc.de/announce13:announce-listll30:http://tracker.ccc.de/announceel42:http://tracker.openbittorrent.com/announceel36:http://tracker.publicbt.com/announceel33:http://tracker.istole.it/announceee10:created by13:mktorrent 1.013:creation datei1342878133e4:infod6:lengthi20598911446e4:name28:earth-20120401130001.osm.bz212:piece lengthi262144e6:pieces0:ee");


BitTorrent::TrackerCore::bt_error ("reason");
my $peer = { 
    'status' => "seed",
    'ip'=>"192.168.1.1",
};

#####
BitTorrent::TrackerCore::setcgi(
    "Mike" => 1,
    'numwant'=>0,
    'event' =>'stopped', # started, completed, ""
    'last' =>1,
    'left' =>1,
    'info_hash' =>"12345678901234567890", # binary info_hash is 20 chars, hex-encoded is 40 chars; accept either
    'ip' => "192.168.1.1",
    'port' =>"1234",
    'peer_id'=>'test',
    'uploaded'=>'123',
    'downloaded'=>'123');

use constant BT_DB_INFO	=>[
    'DBI:SQLite:database=/var/www/tracker/bittracker.sqlite',
    "", "",
    { PrintError=>1, RaiseError=>1, AutoCommit=>1 } 
];

if (!$BitTorrent::TrackerCore::dbh) {
    $BitTorrent::TrackerCore::dbh = DBI->connect(@{(BT_DB_INFO)})
    || die 'Database error.';
}
die "No database" unless $BitTorrent::TrackerCore::dbh;

##################

BitTorrent::TrackerCore::bt_peer_progress ($peer);
BitTorrent::TrackerCore::bt_peer_started ($peer);
BitTorrent::TrackerCore::bt_peer_stopped ($peer);
BitTorrent::TrackerCore::bt_scrape ($peer);

my $torrent = {
    peers => 1,
    seeds => 2,
    
};

BitTorrent::TrackerCore::bt_send_peer_list ($torrent);
#BitTorrent::TrackerCore::check_last_update ();


BitTorrent::TrackerCore::parse_query_string ();
BitTorrent::TrackerCore::print_stats ();



#######################
###summary
BitTorrent::TrackerCore::Connect();

my $sth_summary_ins=$BitTorrent::TrackerCore::dbh->prepare("INSERT INTO bt_summary (sha1) values (?)");
my $sth_names_ins=$BitTorrent::TrackerCore::dbh->prepare("INSERT INTO bt_names (size,mark, sha1,name) values (?,?,?,?)");
my %torrents;
my $counts;
my $now=time();
## loop down through directory reading torrent files
@BitTorrent::TrackerCore::params = (\%torrents,$counts,$now,$sth_summary_ins,$sth_names_ins);
$_= "/var/www/torrents/earth-20120401130001.osm.bz2.torrent";
$File::Find::name="/var/www/torrents/earth-20120401130001.osm.bz2.torrent";
BitTorrent::TrackerCore::process_torrent_files ();

############################

BitTorrent::TrackerCore::read_torrent_file ();
BitTorrent::TrackerCore::refresh_summary ();
BitTorrent::TrackerCore::scan_torrent_dir ();
BitTorrent::TrackerCore::warnerror ();





my $ipdotted    = "69.196.183.186";
use Socket;
my $ipnetwork   = inet_aton($ipdotted);
BitTorrent::TrackerCore::convert_ip_ntoa  ($ipnetwork);
BitTorrent::TrackerCore::html_encode_in_place ("<html> blah </blah>");
my $is_peer=BitTorrent::TrackerCore::is_peer ($ipnetwork,52122);
warn "is peer $is_peer";
