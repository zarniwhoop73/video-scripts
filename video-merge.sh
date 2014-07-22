#!/bin/bash

# "merge" a set of mkv files created for video clips and optionally for captions
# into an mkv for the finished video file.  In practice, everything is encoded
# again.

# uses:
# ffmpeg
# with ... 

# requires at least three parameters - unlike the other scripts in this suite,
# $1 will be the output file, $2 ... are the files to merge.

# variables will go here	

# values for aac : this is the old way, with "default" values
#FREQ=44100
#AAC="-acodec aac -strict experimental -ac 2 -ar $FREQ -ab 96k"
# I use fdk_aac (ffmpeg binaries created with that plus gpl code are not
# redistributable), and my camera only uses a 16 KHz frequency
FREQ=16000
AAC="-acodec libfdk_aac -cutoff $FREQ -b:a 96k"

MYFPS=30 # 30 frames per second - it gets used in a sanity-check
MYPIXELS=1280x720
COUNT=0
WARN=
TITLE=
TITLESTR=

usage () {
	echo "$0 outfile="filename.mkv" [ title="My Title" ] fileA fileB [ fileC, fileD, ...]"
	echo "take existing mkv files and \"merge\" them into a video"
	echo "In practice, they have to be recoded - so take the opportunity"
	echo "to recode the audio to aac, which is an acceptable format for"
	echo "uploading to youtube."
	exit 1
}

yorn() {
	# from http://rosettacode.org/wiki/Keyboard_input/Obtain_a_Y_or_N_response#UNIX_Shell
	# but modified to distinguish y from n !
	echo -n "${1:-Press Y to continue or N to terminate: }"

	shopt -s nocasematch

	until [[ "$ans" == [yn] ]]
	do
		read -s -n1 ans
	done

	echo "$ans"
	if [ "$ans" = "y" ]; then
		return 0
	else
		return 1
	fi

	#shopt -u nocasematch
}


#main line
while [ $# -gt 0 ]; do
	echo $1 | grep -q '=' || break
	LHS=$(echo $1 | cut -d '=' -f 1)
	RHS=$(echo $1 | cut -d '=' -f 2)
	if [ "$LHS" = "outfile" ]; then
		# do outfile validation
		OUTFILE=$RHS
		if [ -f ${OUTFILE} ]; then
			WARN=true
		fi

	elif [ "$LHS" = "title" ]; then
		# set up title
		TITLESTR=$RHS
		TITLE="-metadata title=\"$TITLESTR\""
	else
		echo "ERROR: unexpected parameter $1"
		usage
	fi
	shift
done

if [ -z "$OUTFILE" ]; then
	echo "ERROR: outfile was not set"
	usage
fi

if [ -n "$TITLE" ]; then
	echo "will set title to $TITLESTR"
fi


# validate the specified input files
COUNT=1
# ARGS will be -i file1 -i file2 ...
ARGS=
# COMPLEX will be [0:0] [0:1] [1:0] [1:1] ...
QUOTE="'"
COMPLEX=
# need to save $# because it decrements on each pass
NUMINFILES=$#
echo "$# input files were specified"
while [ $COUNT -le $NUMINFILES ];
do
	echo "checking $1"
	if ! [ -f $1 ]; then
		echo "input file $1 does not exist"
		exit 2
	fi
	FFM=$(ffmpeg -i $1 2>&1)

	echo $FFM | grep -q 'Video: h264 '
	if [ $? -ne 0 ]; then
		echo "ERROR: $1 is not h264 video"
		exit 2
	fi
	# sometimes the pixels have a comma after them, other times not ?
	echo $FFM | grep -q " $MYPIXELS"
	if [ $? -ne 0 ]; then
		echo "ERROR: $1 is not of size $MYPIXELS"
		exit 2
	fi
	echo $FFM | grep -q " $MYFPS fps"
	if [ $? -ne 0 ]; then
		echo "ERROR: $1 is not $MYFPS fps"
		exit 2
	fi
	echo $FFM | grep -q 'Audio: pcm_s16le, '
	if [ $? -ne 0 ]; then
		echo "ERROR: $1 is not pcm_s16le (wav) audio"
		exit 2
	fi

	ARGS="$ARGS -i $1"

	let IDX=$COUNT-1
	COMPLEX="$COMPLEX[${IDX}:0] [${IDX}:1] "

	shift
	let COUNT=$COUNT+1
done

let COUNT=${COUNT}-1

# NB using just -crf 25 in x264 without any other video parms seems to give
# adequately good quality, but the resulting files are around 40% bigger than
# what I previously used.

# putting the command into a string gets around a problem when trying to put
# single quotes around ${COMPLEX}...[a]  and also lets me eval the command to
# execute it, so that I don't have separate "this is what I will do" and
# " run it" versions.
COMMAND="ffmpeg ${ARGS} -filter_complex '${COMPLEX}concat=${COUNT}:v=1:a=1 [v] [a]' -map '[v]' -map '[a]' -s ${MYPIXELS} -vcodec libx264 -crf 25 ${AAC} ${TITLE} -y ${OUTFILE}"

echo "Command is"
echo "$COMMAND"

if [ -n "$WARN" ]; then
	echo "WARNING: $OUTFILE already exists"
fi

echo "Do you wish to run this command? (Y/N)"
yorn
if [ $? -ne 0 ]; then
	echo "abandonned"
	exit 0
fi

time eval $COMMAND

