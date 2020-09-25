#!/bin/bash

LFM_API_KEY=$(<lastfm.token); export LFM_API_KEY
LFM_USER_ID=$(<lastfm.user); export LFM_USER_ID

./lastweekly.pl --user ${LFM_USER_ID} --twitter
