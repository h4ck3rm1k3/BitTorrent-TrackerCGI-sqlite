use DBI;
use constant BT_DB_INFO	=>[
    'DBI:SQLite:database=/var/www/tracker/bittracker.sqlite',
    "", "",
    { PrintError=>1, RaiseError=>1, AutoCommit=>1 } 
];

my $dbh = DBI->connect(@{(BT_DB_INFO)});
my $sth_summary_ins=$dbh->prepare("INSERT INTO bt_summary (sha1) values (?)");	
my $sha1 = "blah";
$sth_summary_ins->execute($sha1);
