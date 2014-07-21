#!/bin/bash

# summarise duration, and number of frames, from a video file.

# pass the (single) filename on the command line.

# uses ffmpeg and mediainfo
# with awk, bc, cut, grep, sed, tail

usage () {
	echo "$0 : report summary details for a video file"
	echo
	echo "Usage: $0 /path/to/video-file"
	exit 1
}

if [ $# -lt 1 ]; then
	usage
fi

if ! [ -f $1 ]; then
	usage
fi

echo "Summary of $1"
# there are various 'Format something' results in some files
RESULTS=$(mediainfo $1 | grep 'Format  ' | wc -l)
# even a file with ponly one stream has a Format match for the file/container
let STREAMS=$RESULTS-1

# for videos I am processing, expect one audio and one video stream
if [ $STREAMS -ne 2 ]; then
	echo "WARNING: $1 contains $STREAMS streams instead of the expected 2 streams."
fi
echo "Stream types is/are:"
mediainfo $1 | grep 'Format  ' | awk '{ print $NF }' | tail -n $STREAMS


echo -n "file length from mediainfo is "
mediainfo $1 | grep -m 1 'Duration  ' | cut -d ':' -f 2

# following are from ffmpeg
DURATION=$(ffprobe $1 2>&1 | grep 'Duration:' | awk '{ print $2 }' | sed 's/,//')
HH=$(echo $DURATION | cut -d ':' -f 1)
MM=$(echo $DURATION | cut -d ':' -f 2)
# seconds can include decimals
SECSD=$(echo $DURATION | cut -d ':' -f 3)
let HHSECS=$HH*60
let MMSECS=$MM*60
SECS=$(echo "$HHSECS + $MMSECS + $SECSD" | bc)

FPS=$(ffmpeg -i $1 2>&1 | sed -n "s/.*, \(.*\) fps.*/\1/p")
echo "Frames per second is $FPS"

FRAMES=$(ffprobe -select_streams v -show_streams $1 2>&1 | grep 'nb_frames' | \
 cut -d '=' -f 2)
if [ "$FRAMES" = "N/A" ]; then
	# ffprobe sometimes reports nb_frames=N/A, so compute them.
	# for my created files, any non-zero decimal shows there are anomalies.
	echo "computing number of frames using duration $DURATION from ffmpeg"
	FRAMES=$(echo "$FPS * $SECS" | bc)
fi
echo "No. of video frames is $FRAMES"

