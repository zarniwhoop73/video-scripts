#!/bin/bash

# convert a png of the correct size ($MYPIXELS) to an mkv video with silent
# 16 KHz wav audio - to match what comes out of video-clip.sh
#
# required parms filename.png time="seconds"
# (only tested for whole numbers of seconds
# this will create filename.{mp4,wav,mkv}
#
# optional:
# vfi="start_frame:no_of_frames" : - video fade in (start_frame should probably be 0)
# vfo="start_frame:no_of_frames" : video fade out - should probably stop at end of file
#
# uses:
# ImageMagick ('display'), pcregrep, sox
# and awk, bc, cut, grep, wc

# these are what my camera produces -
MYFPS=30 # 30 frames per second - it gets used in a sanity-check
MYPIXELS=1280x720
# MYFREQ is the audio sampling frequency.
# for CD format you would use 44100
MYFREQ=16000

INFILE=
OSTEM=
TIMEVAL=
VFI=
VFO=
VOL=
AFADE=
WARN=0

usage() {
	echo "create an mkv caption with a static image and silent wav audio"
	echo "from a png file"
	echo
	echo "parms are specified as name=\"value\""
	echo "Required parms:"
	echo "infile= : the png file to use"
	echo "time= : duration of output"
	echo "optional parms:"
	echo "vfi= : (video fade-in - frame_no:frame_count"
	echo "vfo= : (video fade-out - frame_no:frame_count"
	exit 1
}

lessthan60 () {
	# check that arg - known to be integer and in $SANITIZED -
	# is less than 60 to validate seconds or minutes in hh:mm:ss format
	#echo "lessthan60 called with $1"
	if [ $1 -gt 59 ]; then
		echo "ERROR: invalid time value $1 in $SANITIZED"
		exit 1
	fi
}

check-time () {
	# a time passed to ffmpeg can either be in seconds, or in hh:mm:ss[.xxx]
	# so first check it is a single word
	WC=$(echo $1 | wc -w)
	if [ "$WC" != "1" ]; then
		echo "ERROR invalid time specifier $1"
		exit 1
	fi
	# clear these in case set from a previous argument
	UNITS= ; DECIMALS= ; MINS= ; SECS= ; SIMPLE=
	UNITS=$(echo $1 | cut -d '.' -f 1)
	DECIMALS=$(echo $1 | cut -s -d '.' -f 2)
	#echo "UNITS are $UNITS"
	# the units can either be whole seconds, or in the form hh:mm:ss
	if [ "$UNITS" -eq "$UNITS" ] 2>/dev/null; then
		# a whole number of seconds
		SIMPLE=y
		#echo "not hh:mm:ss"
	else
		# maybe in the hh:mm:ss form - in practice, a duration could
		# theoretically exceed 99 hours and still be valid
		SANITIZED=$(echo "$UNITS" | pcregrep '\d+:\d\d?:\d\d?')
		if [ "$SANITIZED" != "$UNITS" ]; then
			echo "ERROR, units of time not whole seconds nor in HH:MM:SS format"
			echo "input is $UNITS"
			echo "result is $SANITIZED"
			exit 1
		fi
		#echo "apparently in hh:mm:ss style"
		MINS=$(echo $SANITIZED | cut -d ':' -f 2)
		SECS=$(echo $SANITIZED | cut -d ':' -f 3)
		lessthan60 $MINS
		lessthan60 $SECS
	fi
	if [ "$DECIMALS" != "" ]; then
		# check if non-numeric
		if ! [ "$DECIMALS" -eq "$DECIMALS" ] 2>/dev/null; then
			echo "non numeric decimals in time value"
			exit 1
		fi
	fi
	# ok, it is valid.  while we are here, convert to seconds and decimals
	# leaving the result in $SECONDSDEC
	if [ -z "$SIMPLE" ]; then
		# time was hh:mm:ss format
		NORMIFS="$IFS"
		IFS=: read H M S <<<"${1%.*}"
		IFS="$NORMIFS"
		#echo "read values were $H $M $S"
		SECONDS="$(($S+$M*60+$H*3600))"
	else
		SECONDS=$UNITS
	fi
	SECONDSDEC="${SECONDS}.${DECIMALS}"
	#echo SECONDSDEC is $SECONDSDEC
}

frames () {
	# check that $RHS is in the form start_frame:number_of_frames
	# i.e. digits:digits
	echo $RHS | grep -q ':'
	if [ $? -ne 0 ]; then
		echo "invalid frame specification $RHS"
		exit 1
	fi
	FRAME1=$(echo $RHS | cut -d ':' -f 1)
	FRAME2=$(echo $RHS | cut -d ':' -f 2)
	FRAMEWORK=$(echo "$FRAME1" | pcregrep '\d+')
	if [ "$FRAMEWORK" != "$FRAME1" ]; then
		echo "invalid start_frame $FRAME1 in $RHS"
		exit 1
	fi
	FRAMEWORK=$(echo "$FRAME2" | pcregrep '\d+')
	if [ "$FRAMEWORK" != "$FRAME2" ]; then
		echo "invalid frame count $FRAME2 in $RHS"
		exit 1
	fi
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

# functions to process the input parameters.
process-infile () {
# here, the input file must be a png of hte correct size
INFILE=$RHS
if ! [ -f $INFILE ]; then
	echo "ERROR: input file $INFILE not found."
	exit 2
else
	identify $INFILE | grep -q PNG
	if [ $? -ne 0 ]; then
		echo "input file $INFILE is not a png file"
		exit 2
	fi
	PIXELS=$(identify $INFILE | awk '{ print $3 }')
	if [ "$PIXELS" != "$MYPIXELS" ]; then
		echo "This script is set to process captions of size $MYPIXELS"
		echo "but $INFILE has a size of $PIXELS"
		exit 2
	fi
	# now set up the name for remaining files we create
	OSTEM="${INFILE%.*}"
fi
}

process-time () {
	check-time $RHS
	TIMEVAL="$RHS"
	TIMENUM="$SECONDSDEC"
	# for whole seconds, ffmpeg is happy with values in the form 'N.'
	# but sox needs 'N.0', at least if a decimal point is supplied.
	TIMESOX=$TIMENUM
	if [ -z "$DECIMALS" ]; then
		TIMESOX="${TIMESOX}0"
	fi
	EXPECTEDFRAMES=$(echo "$TIMENUM * $MYFPS" | bc)
	echo "expected output frame total is $EXPECTEDFRAMES"
}

process-vfi () {
	# video fade in - requires frame number and number of frames
	frames
	VFISTART=$FRAME1
	VFICOUNT=$FRAME2
}

process-vfo () {
	# video fade out - requires frame number and number of frames
	frames
	VFOSTART=$FRAME1
	VFOCOUNT=$FRAME2
}

# main line

# process the parms
while [ $# -gt 0 ];
do
	echo $1 | grep -q '=' >/dev/null
	if [ $? -ne 0 ]; then
		echo 'ERROR: $1 is not in the form specifyer="value"'
		usage
	fi
	LHS=$(echo $1 | cut -d '=' -f 1)
	RHS=$(echo $1 | cut -d '=' -f 2)
	case $LHS in
		infile)
			process-infile
			;;
		time)
			process-time
			;;
		vfi)
			process-vfi
			;;
		vfo)
			process-vfo
			;;
		*)
			echo "unexpected command $LHS"
			usage
			;;
	esac
	shift
done

# check that the required parms were provided
if [ -z "$INFILE" ]; then
	echo "ERROR: infile= was not specified"
	usage
fi

if [ -z "$TIMENUM" ]; then
	echo "ERROR: time= was not supplied"
	usage
fi

#  if both vfi and vfo were specified, vfi SHOULD finish before vfo
if [ -n "$VFISTART" ]; then
	let FADEINEND="$VFISTART+$VFICOUNT"
	if [ $FADEINEND -gt $EXPECTEDFRAMES ]; then
		echo "WARNING: end of fade IN is after last frame ($EXPECTEDFRAMES)"
		let WARN=$WARN+1
	fi
	if [ -n "$VFOSTART" ]; then
		if [ $FADEINEND -gt $VFOSTART ]; then
			echo "WARNING - fades in and out overlap"
			let WARN=$WARN+1
		fi
	fi
fi

# 3. if vfo was specified, it SHOULD finish AT end of clip
if [ -n "$VFOSTART" ]; then
	let FADEOUTEND="$VFOSTART+$VFOCOUNT"
	if [ $FADEOUTEND -ne $EXPECTEDFRAMES ]; then
		echo "WARNING - fade out finishes at frame $FADEOUTEND not $EXPECTEDFRAMES"
		let WARN=$WARN+1
	fi
fi


# now set up what should go into generated commands

# for vfade, if both exist then they need to be separated by a comma
if [ -n "$VFISTART" ] || [ -n "$VFOSTART" ]; then
	# start the video fade command
	#VFCMD="-vf \""		
	VFCMD="-vf "
	if [ -n "$VFISTART" ]; then
		#fade in
		VFCMD="${VFCMD}fade=in:$VFISTART:$VFICOUNT"
		# if fade out also set, add a comma
		if [ -n "$VFOSTART" ]; then
			VFCMD="${VFCMD},"
		fi
	fi
fi
if [ -n "$VFOSTART" ]; then
	# fade out
	VFCMD="${VFCMD}fade=out:$VFOSTART:$VFOCOUNT"
fi
if [ -n "$VFISTART" ] || [ -n "$VFOSTART" ]; then
	# close the video fade command
	#VFCMD="${VFCMD}\""	
	VFCMD="${VFCMD}"
fi
echo "will set video fade with $VFCMD"

if [ $WARN -gt 0 ]; then
	if [ $WARN -eq 1 ]; then
		echo "*** there was 1 Warning ***"
	else
		echo "** there were $WARN warnings ***"
	fi
fi

# perhaps ought to show the commands anyway ?

yorn
if [ $? -ne 0 ]; then
	echo "abandonned"
	exit 0
fi

# first create an mp4
ffmpeg -loop 1 -i $INFILE -c:v libx264 -t $TIMEVAL $VFCMD -pix_fmt yuv420p -r $MYFPS -y ${OSTEM}.mp4
if ! [ -f ${OSTEM}.mp4 ]; then
	echo "creation of$OSTEM.mp4 frmm $INFILE failed"
	exit 2
fi

# and then create the silent wav of $TIMESOX seconds
echo "command is: sox -n -r $MYFREQ ${OSTEM}.wav trim 0.0 $TIMESOX"
sox -n -r $MYFREQ ${OSTEM}.wav trim 0.0 $TIMESOX
if [ $? -ne 0 ]; then
	echo "creation of silent wav file ${OSTEM}.wav failed"
	exit 2
fi

# and merge them
ffmpeg -i ${OSTEM}.mp4 -i ${OSTEM}.wav -map 0:0 -map 1:0 -c:v copy -c:a copy -y ${OSTEM}.mkv

