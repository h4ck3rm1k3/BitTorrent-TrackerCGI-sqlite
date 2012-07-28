use DBI;
use constant BT_DB_INFO	=>[
    'DBI:SQLite:database=/var/www/tracker/bittracker.sqlite',
    "", "",
    { PrintError=>1, RaiseError=>1, AutoCommit=>1 } 
];

my $dbh = DBI->connect(@{(BT_DB_INFO)});

$dbh->do(qq{
CREATE TABLE IF NOT EXISTS test
(
 sha1 BLOB(20) PRIMARY KEY   NOT NULL
)});


my $sth_summary_ins=$dbh->prepare("INSERT INTO test (sha1) values (?)");	
my $sha1 = "blah";
$sth_summary_ins->execute($sha1);

$sha1= "Ç;%Ly¬x=R#¶ü<.Cß¯";
$sth_summary_ins->execute($sha1);
