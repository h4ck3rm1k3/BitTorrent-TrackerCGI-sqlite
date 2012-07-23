
use LWP::Simple;
my $content = get("http://localhost/tracker/announce?info_hash=%96%0F%B5%EBV%E2%A8V%DC%21k%82%FD%FD%A0%E8%8B%C0%BB%FF&peer_id=-TR2030-2yyx74ct1zl4&port=51416&uploaded=0&downloaded=0&left=0&numwant=80&key=08tv67ed&compact=1&supportcrypto=1&event=started&ipv6=2001%3A0%3A53aa%3A64c%3A3869%3A5ba6%3Aa3cd%3Ab8d4");
print $content;

