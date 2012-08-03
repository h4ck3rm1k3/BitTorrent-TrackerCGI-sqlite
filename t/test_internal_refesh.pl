use lib "/home/mdupont/experiments/fosm/tracker/BitTorrent-TrackerCGI-sqlite/lib";
use BitTorrent::TrackerCore;

#bhandler($r) unless $^C;
#refresh_summary 
BitTorrent::TrackerCore::refresh_summary($^T);
