#!/bin/bash

# I created my youtube uploads as mkv because I needed to convert the
# original mov files to soemthing I can reliably watch locally (mpeg-4 video)
# and to fade in, or out, the audio when creating a clip.
# But I want to be able to watch these in firefox, for convenience,
# and firefox doesn't open mkv files.
#
# For this I'm using mediainfo to minimally sanity-check the input mkv.
# Mine are all Matroska, with video format AVC and audio format AAC LC
# The various mp4 siles I have use AVC video format but audio formats
# of AVC LC, AVC LOC SBR, AAC LC, or MPEG Audio.
# this implies that my AAC LC audio, and AVC video can just be copied.	
#
# This uses ffmpeg (tested with ffmpeg-5.1), mediainfo (the commandline
# version, tested with 21.09) and a standard LFS build.
#
# Usage:
# supply a filename,mkv - this should be an mkv file with AVC video and
# AAC LC audio. The output will be filename.mp4

usage() {
	echo "$0: convert an mkv (Matroska) file,"
	echo "with AVC video and AAC LC audio to mp4."
	echo "The output mp4 will be created in the current directory."
	echo "supply the name of the mkv file"
}

if [ $# -ne 1 ]; then
	usage
	echo
	echo "ERROR: filename of mkv file not supplied"
	exit 1
fi

# main line 

# process the filename
if ! [ -f $1 ]; then
	usage
	echo
	echo "ERROR: $1 not found"
	exit 1
else
	echo "confirming $1 is a Matroska file"
	file $1 | grep 'Matroska data'
	if [ $? -ne 0 ]; then
		echo "$1 is not a Matroska file"
		xit 1
	fi
	echo "confirming mediainfo is installed"
	which mediainfo
	if [ $? -ne 0 ]; then
		echo "This script requires command-line mediainfo to validate the input"
		exit 1
	fi
	echo "Validating codecs"
	VIDEO=$(mediainfo $1 | grep -E '^Format *:' | cut -d ':' -f2 | sed 's/ //' |
	 head -n 2 | tail -n1)
	AUDIO=$(mediainfo $1 | grep -E '^Format *:' | cut -d ':' -f2 | sed 's/ //' |
	 head -n 3 | tail -n1)
	#echo "formats are >$VIDEO< and >$AUDIO<"

fi

# Produce the name of the output file
BASENAME=$(basename $1 .mkv)
OUTFILE="$BASENAME.mp4"

echo "creating $OUTFILE from $1"

ffmpeg -i $1 -c:v copy -c:a copy $OUTFILE
