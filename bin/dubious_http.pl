#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long qw(:config posix_default bundling);
use App::DubiousHTTP::Tests;
use App::DubiousHTTP::Tests::Common;
use App::DubiousHTTP::TestServer;

sub usage {
    print STDERR "ERROR: @_\n" if @_;
    print STDERR <<USAGE;

Test various behaviors of browsers, IDS... by working as a
web server or alternativly creating pcaps with dubios HTTP.
See --mode doc for details about the tests.

Help:               $0 -h|--help
Test descriptions:  $0 -M|--mode doc
Export Pcaps:       $0 -M|--mode pcap target-dir
Use as HTTP server: $0 -M|--mode server [options] ip:port

Options for server mode:
 --cert cert.pem    SSL certificate if SSL should be used. It will listen for
		    SSL and plain requests on the same address.
 --key  key.pem     Key for SSL certificate
 --no-garble-url    Use clear names for URL's instead of the default garbled
		    names which were introduced to defer simple URL filters.
		    Logging will be done always with the clear names.
 --no-track-header  Disable logging of header information for requests, which
		    are used to analyze the origin and path of the request in
		    more detail.
 --fast-feedback    Don't collect all results and send them at once at the end
                    but send parts of the output earlier so that the recipient
		    needs to collect them. This saves memory in the client too.

USAGE
    exit(1);
}

our $BASE_URL="http://foo";
$TRACKHDR=1;
my $mode = 'doc';
my ($cert,$key);
GetOptions(
    'h|help'   => sub { usage() },
    'M|mode=s' => \$mode,
    'no-garble-url' => \$NOGARBLE,
    'track-header!' => \$TRACKHDR,
    'fast-feedback' => \$FAST_FEEDBACK,
    'cert=s'   => \$cert,
    'key=s'    => \$key,
);

if ( $mode eq 'server' ) {
    my $addr = shift(@ARGV) or usage('no listen address given');
    serve($addr, $cert
	? { SSL_cert_file => $cert, SSL_key_file => $key||$cert }
	: ()
    );
} elsif ( $mode eq 'doc' ) {
    print make_doc();
} elsif ( $mode eq 'pcap' ) {
    my $dir = shift(@ARGV) or usage('no target dir for pcap');
    make_pcaps($dir);
} else {
    usage('unknown mode '.$mode);
}

############################ make documentation
sub make_doc {
    my $dok = '';
    for my $cat ( App::DubiousHTTP::Tests->categories ) {
	$cat->TESTS or next;
	$dok .= "[".$cat->ID."] ".$cat->SHORT_DESC."\n";
	for my $tst ( $cat->TESTS ) {
	    $dok .= " - [".$tst->ID."] ".$tst->DESCRIPTION."\n"
	}
    }
    return $dok;
}

############################ create pcap files
sub make_pcaps {
    my $base = shift;
    $NOGARBLE = 1;
    eval { require Net::PcapWriter }
	or die "cannot load Net::PcapWriter\n";
    -d $base or die "$base does not exist";
    for my $cat ( App::DubiousHTTP::Tests->categories ) {
	$cat->TESTS or next;
	( my $id = $cat->ID ) =~s{[^\w\-.,;+=]+}{_}g;
	my $dir = "$base/$id";
	-d $dir or mkdir($dir) or die "cannot create $dir: $!";
	for my $tst ( $cat->TESTS ) {
	    ( my $id = $tst->ID ) =~s{[^\w\-.,;+=]+}{_}g;
	    my $pc = Net::PcapWriter->new( "$dir/$id.pcap" );
	    my $conn = $pc->tcp_conn('1.1.1.1',1111,'8.8.8.8',80);
	    $conn->write(0, "GET ".$tst->url('eicar.txt')." HTTP/1.1\r\nHost: foo.bar\r\n\r\n" );
	    $conn->write(1, $tst->make_response('eicar.txt') );
	}
    }
}

############################ work as server
sub serve {
    my ($addr,$sslargs) = @_;
    my %iscat = map { $_->ID => 1 } App::DubiousHTTP::Tests->categories;

    App::DubiousHTTP::TestServer->run($addr, $sslargs, sub {
	my ($path,$listen,$rqhdr,$payload,$ssl) = @_;
	return "HTTP/1.0 404 not found\r\n\r\n" if $path eq '/favicon.ico';

	if ($path =~m{\A/submit_(details|results|part)/([^/]+)(?:/(\d+))?} && $payload) {
	    my ($what,$id,$part) = ($1,$2,$3);
	    $rqhdr .= $payload;
	    $rqhdr =~s{( /[=-][A-Za-z0-9_\-]+={0,2} )}{ ungarble_url($1) }eg;
	    $rqhdr =~s{^}{ }mg;
	    my $body = '';
	    print STDERR $rqhdr;
	    if ($what ne 'part') {
		$body = "<!doctype html>"
		    ."<h1>Thanks for providing us with the feedback.</h1>";
	    }
	    return "HTTP/1.1 200 ok\r\nContent-type: text/html\r\n".
		"X-ID: $path\r\n".
		"Content-length: ".length($body)."\r\n"
	}

	local $BASE_URL = "http://$listen";
	my ($auto,$src,$cat,$page,$spec,$qstring) = $path =~m{\A / 
	    (?:auto(js|img|html|xhr|)/|((?:raw)?src)/)?
	    ([^/]+)
	    (?: / ([^/\?]*))?
	    (?: / ([^\?]*))?
	    (?: \? (.*))?
	}x;
	for ($cat,$page,$spec,$qstring) {
	    $_ = '' if ! defined $_;
	}

	if (defined $auto && ($iscat{$cat} || $cat eq 'all')) {
	    return App::DubiousHTTP::Tests->auto(
		$auto || 'xhr',$cat,$page,$spec,$qstring,$rqhdr)
	}

	if ( $page eq 'ALL' && $cat ) {
	    for ( App::DubiousHTTP::Tests->categories ) {
		return $_->make_index_page(undef,,$spec,$rqhdr)
		    if $_->ID eq $cat;
	    }
	}


	if ( $page && $cat ) {
	    for ( App::DubiousHTTP::Tests->categories ) {
		$_->ID eq $cat or next;
		my $content = '';
		for ( $_->TESTS ) {
		    $_->ID eq $spec or next;
		    $content = $_->make_response($page,undef,$rqhdr);
		    last;
		}
		$content ||= $_->make_response($page,$spec,$rqhdr);
		if (!$src) {
		    return $content;
		} elsif ($src eq 'rawsrc') {
		    return "HTTP/1.0 200 ok\r\n".
			"Content-type: application/octet-stream\r\n".
			"Content-Disposition: attachment; filename=\"$cat+$page+$spec\"\r\n".
			"Content-length: ".length($content)."\r\n\r\n".$content;
		} else {
		    $content =~s{([\x00-\x1f\\<>\x7f-\xff])}{
			$1 eq "\\" ? "\\\\" :
			$1 eq "\r" ? "\\r" :
			$1 eq "\t" ? "\\t" :
			$1 eq "\n" ? "\\n\n" :
			$1 eq "<" ? "&lt;" :
			$1 eq ">" ? "&gt;" :
			sprintf("\\x%02x",ord($1))
		    }esg;

		    (my $raw = $path) =~s{/src/}{/rawsrc/};
		    $content = "<pre>$content</pre><hr>".
			"<a class=srclink href=".garble_url($raw).">raw source</a>";

		    return "HTTP/1.0 200 ok\r\n".
			"Content-type: text/html\r\n".
			"Content-length: ".length($content)."\r\n\r\n".$content;
		    
		}

	    }
	}

	if ( my ($hdr,$data) = content($path)) {
	    return "HTTP/1.0 200 ok\r\n$hdr\r\n$data";
	} elsif ( $path =~m{^([^?]+)(?:\?(.*))?} and ($hdr,$data) = content($1,$2) ) {
	    return "HTTP/1.0 200 ok\r\n$hdr\r\n$data";
	}

	if ( $cat ) {
	    for ( App::DubiousHTTP::Tests->categories ) {
		return $_->make_index_page($page,$spec,$rqhdr)
		    if $_->ID eq $cat;
	    }
	}

	return App::DubiousHTTP::Tests->make_response($cat,$page,$spec,$rqhdr);
    });
}

