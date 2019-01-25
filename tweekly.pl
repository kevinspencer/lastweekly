#!/usr/bin/env perl
# Copyright 2018-2019 Kevin Spencer <kevin@kevinspencer.org>
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
use Env '@PATH';
use File::HomeDir;
use File::stat;
use Getopt::Long;
use JSON::XS;
use LWP::UserAgent;
use URI;
use strict;
use warnings;

our $VERSION = '0.6';

$Data::Dumper::Indent = 1;

my ($artists_to_count, $lastfm_user, $force, $twitter, $debug);
GetOptions("count=i" => \$artists_to_count, "user=s" => \$lastfm_user, "twitter" => \$twitter, "debug" => \$debug, "force" => \$force);

die "No user provided, USAGE: tweekly.pl --user oldmanrivers\n" if (! $lastfm_user);

$artists_to_count ||= 5;

my $twitter_poster = 'burdie';
# if we're posting to twitter, ensure burdie is in our path
if ($twitter) {
    push(@PATH, File::HomeDir->my_home() . '/bin');
    if (! grep -x "$_/$twitter_poster", @PATH) {
        die "You wanted to post to Twitter but I can't find any tool to do that.\n";
    }
}

my $api_key = $ENV{LFM_API_KEY} or die "No last.fm API key found\n";

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
$ua->agent('tweekly.pl/' . $VERSION);
my $response = $ua->get($uri);
if (! $response->is_success()) {
    die "Error when communicating with $api_url: " . $response->status_line(), "\n";
}

my $data = decode_json($response->content());
if ($data->{error}) {
    die "ERROR $data->{error}: $data->{message}\n";
}

my $artists = $data->{topartists}{artist};

my $twitter_post_string = 'My top ' . $artists_to_count . ' #lastfm artists: ';

my $counter = 0;
for my $artist (@$artists) {
    if ($counter == 0) {
        $twitter_post_string .= "$artist->{name} ($artist->{playcount})";
    } elsif ($counter == ($artists_to_count - 1)) {
        $twitter_post_string .= " & $artist->{name} ($artist->{playcount})";
    } else {
        $twitter_post_string .= ", $artist->{name} ($artist->{playcount})";
    }
    $counter++;
    last if ($counter == $artists_to_count);
}

$twitter_post_string .= " via tweekly.pl";

print $twitter_post_string, "\n";

# TODO: instead of shelling out, incorporate burdie code here...
if ($twitter) {
    my $shell_command = "$twitter_poster \Q$twitter_post_string\E";
    my $result = `$shell_command`;
    print $result, "\n";
}
