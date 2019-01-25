#!/bin/bash

LFM_API_KEY=$(<.lastfm.token); export LFM_API_KEY

./tweekly.pl --user kevinspencer --twitter
