#!/usr/bin/env perl
# Copyright 2018-2024 Kevin Spencer <kevin@kevinspencer.org>
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

use Data::Dumper;
use Encode;
use Getopt::Long;
use JSON::XS;
use LWP::UserAgent;
use URI;
use utf8;
use strict;
use warnings;

our $VERSION = '0.15';

$Data::Dumper::Indent = 1;

my ($artists_to_count, $force, $debug);
GetOptions("count=i" => \$artists_to_count, "debug" => \$debug, "force" => \$force);

my $lastfm_user = $ENV{LFM_USER_ID} or die "No last.fm username found\n";
my $api_key     = $ENV{LFM_API_KEY} or die "No last.fm API key found\n";

$artists_to_count ||= 5;

my $api_url = 'http://ws.audioscrobbler.com/2.0/';
my $uri = URI->new($api_url);
my %params = (
    api_key => $api_key,
    method  => 'user.getTopArtists',
    user    => $lastfm_user,
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

my $artists = $data->{topartists}{artist};

my $downstream_post_string = '<a href="https://www.last.fm/user/kevinspencer">Who did I listen to most this week?</a>  #lastfm says: ';

my $counter = 0;
for my $artist (@$artists) {
    if ($counter == 0) {
        $downstream_post_string .= "$artist->{name} ($artist->{playcount})";
    } elsif ($counter == ($artists_to_count - 1)) {
        $downstream_post_string .= " & $artist->{name} ($artist->{playcount})";
    } else {
        $downstream_post_string .= ", $artist->{name} ($artist->{playcount})";
    }
    $counter++;
    last if ($counter == $artists_to_count);
}

$downstream_post_string .= ' [via <a href="https://github.com/kevinspencer/lastweekly">lastweekly</a>]';

$downstream_post_string = encode_utf8($downstream_post_string);

print $downstream_post_string, "\n";
