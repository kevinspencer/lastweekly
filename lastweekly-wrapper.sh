#!/bin/bash

LFM_API_KEY=$(<.lastfm.token); export LFM_API_KEY

./lastweekly.pl --user kevinspencer --twitter
