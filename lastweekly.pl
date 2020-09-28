#!/usr/bin/env perl
# Copyright 2018-2020 Kevin Spencer <kevin@kevinspencer.org>
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
use File::HomeDir;
use File::Spec;
use File::stat;
use Getopt::Long;
use IO::Prompt;
use JSON::XS;
use LWP::UserAgent;
use Try::Tiny;
use Twitter::API;
use Twitter::API::Util 'is_twitter_api_error';
use URI;
use strict;
use warnings;

our $VERSION = '0.11';

$Data::Dumper::Indent = 1;

my ($artists_to_count, $lastfm_user, $force, $twitter, $debug);
GetOptions("count=i" => \$artists_to_count, "user=s" => \$lastfm_user, "twitter" => \$twitter, "debug" => \$debug, "force" => \$force);

die "No user provided, USAGE: lastweekly.pl --user oldmanrivers\n" if (! $lastfm_user);

$artists_to_count ||= 5;

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

my $twitter_post_string = "Who did I listen to most this week?  #lastfm says: ";

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

$twitter_post_string .= " via #lastweekly.  https://www.last.fm/user/" . $lastfm_user;

print $twitter_post_string, "\n";

#
# Twitter logic from here on down
#

my $tokens_file = File::Spec->catfile(File::HomeDir->my_home(), '.burdie_tokens');

#
# consumer_key and consumer_secret are provided by twitter on app registration.
# twitter uses these to identify the app in question.  not ideal to hardcode
# these here but no real choice thanks to the odd implementation of OAuth by twitter.
# see:
#
# http://arstechnica.com/security/2010/09/twitter-a-case-study-on-how-to-do-oauth-wrong/
#

my $consumer_key    = 'supflerNwc0EZGHugqjtSA';
my $consumer_secret = 'nOJ5EAkNW7bG7TUEpVUD1N6AQIfnMpEWIGsaSZ9BJYM';

my $client = Twitter::API->new_with_traits(
    traits              => [ qw/Migration ApiMethods RetryOnError/ ],
    consumer_key        => $consumer_key,
    consumer_secret     => $consumer_secret,
);

#
# access_token and access_token_secret are given on a per-user basis by twitter
# once the user has authorized burdie access to their account.  if we've been
# authorized before, there should be access tokens on disk...
#
my($access_token, $access_token_secret) = retrieve_tokens();
if (! ($access_token && $access_token_secret)) {
    ($access_token, $access_token_secret) = get_twitter_authorization();
}

$client->access_token($access_token);
$client->access_token_secret($access_token_secret);

try {
    my $r = $client->verify_credentials;
}
catch {
    die $_ unless is_twitter_api_error($_);

    print $_->http_request->as_string;
    print $_->http_response->as_string;
    print 'No use retrying right away' if $_->is_permanent_error;
    if ( $_->is_token_error ) {
        print "There's something wrong with this token."
    }
    print $_->twitter_error_code;
};

my $result = $client->update($twitter_post_string);
if ($result->{id}) {
    print "SUCCESS: post sent to Twitter, ID: $result->{id}\n";
}

sub get_twitter_authorization {
    my $request = $client->oauth_request_token();

    my $auth_url = $client->oauth_authorization_url({ oauth_token => $request->{oauth_token} });

    print "Visit the following URL in your browser to authorize this app:\n" .
        $client->oauth_authorization_url( { oauth_token => $request->{oauth_token} } ) . "\n";

    my $pin = prompt("Once done, enter the PIN here: ");

    try {
        print "PIN received, contacting twitter to obtain access tokens...\n";
        my $access = $client->oauth_access_token({
            token        => $request->{oauth_token},
            token_secret => $request->{oauth_token_secret},
            verifier     => $pin
        });

        my ($access_token, $access_token_secret) = @{$access}{qw(oauth_token oauth_token_secret)};

        if ($access_token && $access_token_secret) {
            print "Tokens received, storing to $tokens_file...\n";
            store_tokens($access_token, $access_token_secret);
            print "Done.\n";
            return ($access_token, $access_token_secret);
        } else {
            print "Twitter error: did not receive access tokens.\n";
            return;
        }
    }
    catch {
        die $_ unless is_twitter_api_error($_);

        print $_->http_request->as_string;
        print $_->http_response->as_string;
        print $_->twitter_error_code;
    }
}

sub retrieve_tokens {
    if (-e $tokens_file) {
        open(my $fh, '<', $tokens_file) ||
            die "Could not read $tokens_file - $!\n";
        my $a_token = <$fh>;
        chomp($a_token);
        my $a_secret = <$fh>;
        chomp($a_secret);
        close($fh);
        return ($a_token, $a_secret);
    }
    return;
}

sub store_tokens {
    my ($a_token, $a_token_secret) = @_;

    open(my $fh, '>', $tokens_file) ||
        die "Could not create $tokens_file - $!\n";
    print $fh $a_token, "\n";
    print $fh $a_token_secret, "\n";
    close($fh);
}
