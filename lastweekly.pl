#!/usr/bin/env perl
# Copyright 2018-2026 Kevin Spencer <kevin@kevinspencer.org>
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
use Encode qw(encode_utf8);
use Getopt::Long;
use JSON::XS;
use LWP::UserAgent;
use open qw(:std :utf8);
use URI;
use XMLRPC::Lite;
use utf8;
use strict;
use warnings;

our $VERSION = '0.30';

my $config_file = 'lastweekly.conf';

my ($artists_to_count, $draft, $output_only);

GetOptions(
    "count=i"     => \$artists_to_count,
    "draft"       => \$draft,
    "outputonly"  => \$output_only,
    "config=s"    => \$config_file,
);

my $config = Config::Tiny->read($config_file);
die "Could not read $config_file: $Config::Tiny::errstr\n" unless $config;

for my $key (qw(apiurl apikey user useragent)) {
    die "Missing lastfm.$key in config\n" if (! defined $config->{lastfm}{$key});
}

for my $key (qw(proxy user pass)) {
    die "Missing wordpress.$key in config\n" if (! defined $config->{wordpress}{$key});
}

$artists_to_count ||= 5;

my $api_url = $config->{lastfm}{apiurl};
my $uri = URI->new($api_url);
my %params = (
    api_key => $config->{lastfm}->{apikey},
    method  => 'user.getTopArtists',
    user    => $config->{lastfm}->{user},
    period  => '7day',
    format  => 'json'
);
$uri->query_form(%params);

my $ua = LWP::UserAgent->new(
    timeout => 15,
    agent   => $config->{lastfm}{useragent} . '/' . $VERSION,
);
my $response = $ua->get($uri);
if (! $response->is_success()) {
    die "Error when communicating with $api_url: " . $response->status_line(), "\n";
}

my $data;

eval { 
    $data = decode_json($response->content());
};

die "Invalid JSON from Last.fm\n" if $@;

if ($data->{error}) {
    die "ERROR $data->{error}: $data->{message}\n";
}

my $artists = $data->{topartists}{artist} or die "Unexpected API response format (missing artists).\n";
$artists = [$artists] if ref($artists) eq 'HASH';

my $limit = @$artists < $artists_to_count ? @$artists : $artists_to_count;
my @top   = map { "$_->{name} ($_->{playcount})" } @$artists[0 .. $limit - 1];

my $artist_string =
    @top == 1 ? $top[0]
  : @top == 2 ? join(' and ', @top)
  : join(', ', @top[0 .. $#top - 1]) . ", and $top[-1]";

my $downstream_post_string = qq{
<a href="https://www.last.fm/user/kevinspencer">Who did I listen to most this week?</a>  #lastfm says: $artist_string [via <a href="https://github.com/kevinspencer/lastweekly">lastweekly</a>]
};

$downstream_post_string = encode_utf8($downstream_post_string);

print $downstream_post_string, "\n";

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

die sprintf("XML-RPC Fault (%s): %s\n", $rpc->faultcode, $rpc->faultstring) if ($rpc->fault);

print $rpc->result(), "\n";

