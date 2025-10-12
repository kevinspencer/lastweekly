#!/usr/bin/env perl
# Copyright 2018-2025 Kevin Spencer <kevin@kevinspencer.org>
#
# Permission to use, copy, modify, distribute, and sell this software and its
# documentation for any purpose is hereby granted without fee, provided that
# the above copyright notice appear in all copies and that both the
# copyright notice and this permission notice appear in supporting
# documentation.  No representations are made about the suitability of this
# software for any purpose.  It is provided "as is" without express or 
# implied warranty.
#
################################################################################
#
# Uses the last.fm API (http://www.last.fm/api/intro) and requires an API key.
#
################################################################################

use Config::Tiny;
use Data::Dumper;
use Encode;
use Getopt::Long;
use JSON::XS;
use LWP::UserAgent;
use URI;
use XMLRPC::Lite;
use utf8;
use strict;
use warnings;

our $VERSION = '0.21';

$Data::Dumper::Indent = 1;

my $config_file = 'lastweekly.conf';

my ($artists_to_count, $draft, $debug, $output_only);

GetOptions(
    "count=i"     => \$artists_to_count,
    "debug"       => \$debug,
    "draft"       => \$draft,
    "outputonly"  => \$output_only,
    "config=s"    => \$config_file,
);

my $config = Config::Tiny->read($config_file);
die "Could not read $config_file: $Config::Tiny::errstr\n" unless $config;

$artists_to_count ||= 5;

my $api_url = 'http://ws.audioscrobbler.com/2.0/';
my $uri = URI->new($api_url);
my %params = (
    api_key => $config->{lastfm}->{apikey},
    method  => 'user.getTopArtists',
    user    => $config->{lastfm}->{user},
    period  => '7day',
    format  => 'json'
);
$uri->query_form(%params);

my $ua = LWP::UserAgent->new();
$ua->agent('lastweekly.pl/' . $VERSION);
my $response = $ua->get($uri);
if (! $response->is_success()) {
    die "Error when communicating with $api_url: " . $response->status_line(), "\n";
}

my $data = decode_json($response->content());
if ($data->{error}) {
    die "ERROR $data->{error}: $data->{message}\n";
}

my $artists = $data->{topartists}{artist} or die "Unexpected API response format (missing artists).\n";

my $counter = 0;
my $artist_string;
for my $artist (@$artists) {
    if ($counter == 0) {
        $artist_string .= "$artist->{name} ($artist->{playcount})";
    } elsif ($counter == ($artists_to_count - 1)) {
        $artist_string .= " & $artist->{name} ($artist->{playcount})";
    } else {
        $artist_string .= ", $artist->{name} ($artist->{playcount})";
    }
    $counter++;
    last if ($counter == $artists_to_count);
}

my $downstream_post_string = qq{
<a href="https://www.last.fm/user/kevinspencer">Who did I listen to most this week?</a>  #lastfm says: $artist_string [via <a href="https://github.com/kevinspencer/lastweekly">lastweekly</a>]
};

$downstream_post_string = encode_utf8($downstream_post_string);

print $downstream_post_string, "\n" if ($debug);

exit() if ($output_only);

my @posttags = qw(last.fm microblog);
my $wpproxy  = $config->{wordpress}->{proxy};
my $wpuser   = $config->{wordpress}->{user};
my $wppass   = $config->{wordpress}->{pass};
my $blogid   = 1;
my $wpcall   = 'metaWeblog.newPost';

my $status = $draft ? 'draft' : 'publish';

my $rpc = XMLRPC::Lite->proxy($wpproxy)->call($wpcall, $blogid, $wpuser, $wppass,
    {
        description       => $downstream_post_string,
        title             => '',
        post_status       => $status,
        mt_allow_comments => 1,
        mt_keywords       => \@posttags,
    }, 1);

die "XML-RPC Fault: " . $rpc->faultstring . "\n" if ($rpc->fault());

print $rpc->result(), "\n" if ($debug);

