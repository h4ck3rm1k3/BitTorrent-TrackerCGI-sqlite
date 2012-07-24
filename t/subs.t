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
$BitTorrent::TrackerCode::cgi{'numwant'}=0;
$BitTorrent::TrackerCode::cgi{'event'}='stopped'; # started, completed, ""
$BitTorrent::TrackerCode::cgi{'last'}=1;
$BitTorrent::TrackerCode::cgi{'left'}=1;
$BitTorrent::TrackerCode::cgi{'info_hash'}="12345678901234567890"; # binary info_hash is 20 chars, hex-encoded is 40 chars; accept either
$BitTorrent::TrackerCode::cgi{'ip'}="192.168.1.1";
$BitTorrent::TrackerCode::cgi{'port'}="1234";
$BitTorrent::TrackerCode::cgi{'peer_id'}='test';
$BitTorrent::TrackerCode::cgi{'uploaded'}='123';
$BitTorrent::TrackerCode::cgi{'downloaded'}='123';

use constant BT_DB_INFO	=>[
    'DBI:SQLite:database=/var/www/tracker/bittracker.sqlite',
    "", "",
    { PrintError=>1, RaiseError=>1, AutoCommit=>1 } 
];

if (!$BitTorrent::TrackerCode::dbh) {
    $BitTorrent::TrackerCode::dbh = DBI->connect(@{(BT_DB_INFO)})
    || die 'Database error.';
}
die "No database" unless $BitTorrent::TrackerCode::dbh;

##################

BitTorrent::TrackerCore::bt_peer_progress ($peer);
BitTorrent::TrackerCore::bt_peer_started ();
BitTorrent::TrackerCore::bt_peer_stopped ();
BitTorrent::TrackerCore::bt_scrape ();
BitTorrent::TrackerCore::bt_send_peer_list ();
BitTorrent::TrackerCore::check_last_update ();
BitTorrent::TrackerCore::convert_ip_ntoa  ();
BitTorrent::TrackerCore::html_encode_in_place ();
BitTorrent::TrackerCore::is_peer ();
BitTorrent::TrackerCore::parse_query_string ();
BitTorrent::TrackerCore::print_stats ();
BitTorrent::TrackerCore::process_torrent_files ();
BitTorrent::TrackerCore::read_torrent_file ();
BitTorrent::TrackerCore::refresh_summary ();
BitTorrent::TrackerCore::scan_torrent_dir ();
BitTorrent::TrackerCore::warnerror ();


