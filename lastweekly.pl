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
# Artist images come from the Deezer API (no key required) and are hotlinked.
#
################################################################################

use Config::Tiny;
use Getopt::Long;
use HTML::Entities qw(encode_entities);
use HTTP::Request;
use JSON::XS;
use LWP::UserAgent;
use open qw(:std :utf8);
use URI;
use XMLRPC::Lite;
use utf8;
use strict;
use warnings;

our $VERSION = '0.40';

my $config_file = 'lastweekly.conf';

my $deezer_search_url = 'https://api.deezer.com/search/artist';
my $bar_color         = '#888888';
my $image_size        = 64;

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
die "No artists returned for the past week.\n" if (! @$artists);

my $limit = @$artists < $artists_to_count ? @$artists : $artists_to_count;
my @top   = @$artists[0 .. $limit - 1];

for my $artist (@top) {
    $artist->{image} = find_artist_image($artist->{name});
}

my $downstream_post_string = build_post_html(\@top);

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

die sprintf("XML-RPC Fault (%s): %s\n", $rpc->faultcode(), $rpc->faultstring()) if ($rpc->fault());

print $rpc->result(), "\n";

# Look the artist up on Deezer. Deezer often has duplicate artist profiles with
# the same name, so among exact (case-insensitive) name matches take the one
# with the most fans, falling back to the next one if its picture is missing.
# Returns an image URL, or undef if none could be found. Never dies: a missing
# image just means the row is rendered without one.
sub find_artist_image {
    my $name = shift;

    my $search = URI->new($deezer_search_url);
    $search->query_form(q => $name, limit => 10);

    my $res = $ua->get($search);
    if (! $res->is_success()) {
        warn "Deezer search failed for '$name': " . $res->status_line() . "\n";
        return;
    }

    my $hits = eval { decode_json($res->content())->{data} };
    return if (ref($hits) ne 'ARRAY');

    my @candidates =
        sort { ($b->{nb_fan} || 0) <=> ($a->{nb_fan} || 0) }
        grep { lc($_->{name}) eq lc($name) } @$hits;

    for my $candidate (@candidates) {
        my $url = $candidate->{picture_medium};
        return $url if ($url && image_exists($url));
    }

    warn "No Deezer image found for '$name'\n";
    return;
}

# Deezer answers a missing artist picture with a 302 to a generic placeholder,
# so only a direct 200 with an image content type counts as a real picture.
sub image_exists {
    my $url = shift;

    my $res = $ua->simple_request(HTTP::Request->new(HEAD => $url));
    return ($res->code() == 200 && ($res->header('Content-Type') || '') =~ m{^image/});
}

# Build the post body. Everything that matters for presentation is inline
# because WordPress themes and RSS readers drop or override stylesheets. If a
# reader strips the inline styles, the bars vanish but the rank, image, name
# and play count still read as a ranked list. The table is emitted without
# newlines so that wpautop() does not inject <p>/<br> tags into it. Text and
# link colours are deliberately not set so that they inherit from the theme
# (light and dark mode) and from feed readers.
sub build_post_html {
    my $top = shift;

    my $max = $top->[0]{playcount} || 1;
    my $user = encode_entities($config->{lastfm}{user});

    my $rows = '';
    my $rank = 0;

    for my $artist (@$top) {
        $rank++;

        my $name  = encode_entities($artist->{name});
        my $pct   = int(100 * $artist->{playcount} / $max + 0.5);
        $pct = 2 if ($pct < 2);
        my $plays = $artist->{playcount} == 1 ? '1 play' : "$artist->{playcount} plays";

        my $img = '';
        if ($artist->{image}) {
            my $src = encode_entities($artist->{image});
            $img = qq{<img src="$src" width="$image_size" height="$image_size" alt="$name" }
                 . qq{style="display:block;margin:0;width:${image_size}px;height:${image_size}px;max-width:none;object-fit:cover;border-radius:4px;" />};
        }

        # One row per artist: image cell + a vertically centred text cell. The
        # text cell holds a small inner table (name left, play count right, so
        # they always share a line) with the bar directly beneath it, so the
        # name/bar/count block sits as a unit in the middle of the image.
        $rows .= qq{<tr>}
               . qq{<td width="$image_size" style="width:${image_size}px;padding:6px 14px 6px 0;vertical-align:middle;border:0;">$img</td>}
               . qq{<td style="padding:6px 0;vertical-align:middle;border:0;">}
               . qq{<table width="100%" style="width:100%;border-collapse:collapse;margin:0;"><tr>}
               . qq{<td style="padding:0;font-size:0.9em;line-height:1.3;border:0;">$rank. $name</td>}
               . qq{<td style="padding:0 0 0 14px;font-size:0.9em;line-height:1.3;text-align:right;white-space:nowrap;border:0;">$plays</td>}
               . qq{</tr></table>}
               . qq{<div style="margin-top:5px;height:8px;border-radius:4px;background:rgba(136,136,136,0.18);">}
               . qq{<div style="width:$pct%;height:8px;border-radius:4px;background:$bar_color;"></div></div>}
               . qq{</td>}
               . qq{</tr>};
    }

    return qq{<p><a href="https://www.last.fm/user/$user">Who did I listen to most this week?</a> #lastfm says:</p>\n}
         . qq{<table width="100%" style="width:100%;border-collapse:collapse;margin:0 0 1.5em;">$rows</table>\n}
         . qq{<p>[via <a href="https://github.com/kevinspencer/lastweekly">lastweekly</a>]</p>};
}
