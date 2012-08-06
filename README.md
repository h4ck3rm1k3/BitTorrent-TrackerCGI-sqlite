BitTorrent-TrackerCGI-sqlite
============================

BitTorrent::TrackerCGI port to sqlite

From :
http://www.gluelogic.com/code/BitTorrent/TrackerCGI.pm


INSTALL
========
Run this to create the database
  perl -I lib/ t/recreate.t

Configure the script :
  emacs lib/BitTorrent/TrackerCore.pm

Create the torrents dir :
  mkdir /pine02/www/torrents

Copy a torrent into it:
 cp /pine02/www/planet/torrents/earth-20120401130001.osm.bz2.torrent  /pine02/www/torrents/

Touch these output files: 
  touch /pine02/www/torrents/bt_stats.inc
  touch /pine02/www/torrents/bt_rss.rss

Run this to create the list of torrents 
  perl -I lib/ t/test_internal_refesh.pl

ABLES
==========

bt_summary
==========

inserted into by statement named 'summary_update'
queried by statement named 'summary_sha1

Updated by the routine refresh_summary.