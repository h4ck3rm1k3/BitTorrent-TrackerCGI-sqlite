
use LWP::Simple;
my $content = get("http://localhost/announce/scrape?info_hash=%96%0F%B5%EBV%E2%A8V%DC%21k%82%FD%FD%A0%E8%8B%C0%BB%FF");
print $content;
#/scrape?info_hash=%96%0F%B5%EBV%E2%A8V%DC%21k%82%FD%FD%A0%E8%8B%C0%BB%FF
