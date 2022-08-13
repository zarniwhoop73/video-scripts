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
# Later experimentation shows that some mkv files have other audio codecs
# which tend not to work, giving a silent result unless recoded.
#
# This uses ffmpeg (tested with ffmpeg-5.1), mediainfo (the commandline
# version, tested with 21.09) and a standard LFS build.  If the audio
# format needs to be recoded (I found one mkv with ogg audio, which
# resulted in silent ouput without recoding) I assume that ffmpeg has
# been built with libfdk_aac (a nont redistributable build).  If you
# do not have that, I suppose AAC="-c:a aac -b:a 192k" from the ffmpeg
# wiki will do an adequate job.
#
# Usage:
# supply a filename,mkv - this should be an mkv file with AVC video and
# AAC LC audio. The output will be filename.mp4
#

# if needing to record (see above)
FREQ=16000
AAC="-acodec libfdk_aac -cutoff $FREQ -b:a 96k"


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
		echo "ERROR: $1 is not a Matroska file"
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
	# FIXME - forgot to test these formats!			
	if [ "$VIDEO" != "AVC" ]; then
		echo "WARNING: $1 is $VIDEO not Advanced Video Codec"
		RECODE=true
		sleep 3
	fi
	if [ "$AUDIO" = "AAC LC" ] || [ "$AUDIO" = "AVC LC" ] | [ "$AUDIO" = "ACV LC SBR" ]; then
		SOUND=ok
	elif [ "$AUDIO" = "MPEG Audio" ]; then
		SOUND=maybe
		echo "Uncertain if sound will work, please review result"
		sleep 2
	else
		echo "Audio format $AUDIO is not compatible with an mp4 file"
		echo "Will need to recode it"
		SOUND=recode
		sleep 2
	fi

fi

# Produce the name of the output file
BASENAME=$(basename $1 .mkv)
OUTFILE="$BASENAME.mp4"

# sort out what to do
echo "creating $OUTFILE from $1"
if [ "$RECODE" = "true" ]; then
	# assume default crf 23 will be good enough
	# for both -c:v and -vcodec the - is removed
	# using --vcodec gives Unrecognized option '-vcodec libx264'
	# if I hard-code -c:v and pass libx264 I get
	# Unable to find a suitable output format for 'libx264'
	# So, try hardcoding the parts
	if [ "$SOUND" != "recode" ]; then
		ffmpeg -i $1 -c:v libx264 -c:a copy $OUTFILE
	else
		ffmpeg -i $1 -c:v libx264 $AAC $OUTFILE
	fi
else
	if [ "$SOUND" != "recode" ]; then
		ffmpeg -i $1 -c:v copy -c:a copy $OUTFILE
	else
		ffmpeg -i $1 -c:v copy $AAC $OUTFILE
	fi
fi

sleep 5
ffmpeg -i $1 $FFV $FFA $OUTFILE
