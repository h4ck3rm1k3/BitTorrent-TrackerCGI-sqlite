
use LWP::Simple;
my $content = get("http://localhost/announce/scrape?info_hash=12345678901234567890&peer_id=ABCDEFGHIJKLMNOPQRST&ip=255.255.255.255&port=6881&downloaded=1234&left=98765&event=stopped");
print $content;

