#!/bin/bash

# a script to convert a clip from my camera (.mov) to .mp4, with optional start offset and duration,
# and then extract the audio to a .wav file, with optional volume setting
# and then fade in/out the wav audio (technically optional)
# and finally merge the two into an mkv wrapper.
# wav can be faded, aac cannot, and wav tends to keep the same duration as the video stream,
# which is why they end up in an mkv container - mp4 requires aac, and aac audio streams
# always seem to turn out longer than the video.

# uses ffmpeg (tested with ffmpeg-2.2.2), pcregrep, sox,
# plus a standard LFS build e.g. awk, bc, cut, wc

# all parameters are in the form name#"value" and are processed in the
# order in which they are supplied, so if you supply settings for any
# parameter, the last will be used.
#
# required:
# input file : infile=
# output stem (i.e. the name part of the created files) : outstem=
#
# optional
# start time : start=
# start= might not work exactly as expected (you can only seek to a key
# frame)
# duration : time=
# video fade in vfi= (frame number:frames) - the numbering appears to
# begin at the first frame of the input file, which makes a difference
# if you use start=
# video fade out vfo= (frame number:frames)
# audio volume : vol= (255 for the same as the input)
# audio fades (passed to sox) afade=
# Constant Rate Factor, crf=
#  for ffmpeg's x264 encoding, overwrites my default in $CRF
# text : text, for a white 24pt caption in the centre of the picture.
#  - this requires ffmpeg to be built with --enable-libfreetype.

# these are what my camera produces -
MYFPS=30 # 30 frames per second - it gets used in a sanity-check
MYPIXELS=1280x720

# values for aac : this is the old way, with "default" values
# my camera's mov files are only 16k rate, but 44k1 does no harm.
#FREQ=44100
#AAC="-acodec aac -strict experimental -ac 2 -ar $FREQ -ab 96k"
# I use fdk_aac (ffmpeg binaries created with that plus gpl code are not
# redistributable), and my camera only uses a 16 KHz frequency
FREQ=16000
AAC="-acodec libfdk_aac -cutoff $FREQ -b:a 96k"

INFILE=
OSTEM=
TIMEVAL=
VFI=
VFO=
VOL=
AFADE=
WARN=0
TITLE=
TITLESTR=
MYSELF=$(basename $0)
# for work files, -crf 24 but for the final version -crf 22
# to reduce the size at the expense of a little quality.
# 21 throughout is a better quality (if the pictures are reasonable
# quality - on my automatic, many are not) but the resulting
# upload (unless the duration is very short) will be unmanageably slow.
if [ "$MYSELF" = "video-single.sh" ]; then
	CRF=24
	MERGEMSG="copying the video, recoding the audio to aac in an mkv container"
	AUDIO="${AAC}"
else
	CRF=22
	MERGEMSG="merging the wav audio with the x264 video in an mkv container"
	AUDIO="-c:a copy"
fi

# for text which uses the process-text function, to set a caption
# the first three ought to be settable by exporting them, but trying to
# correctly export a position for the text seems silly.

#TEXTFONT does not need a value if DejaVu Sans is available to fontconfig
# -defer testing this until it is required
#TEXTFONT= # /path/to/ttf-or-otf

# The Pts size for the font
if [ -z "$TEXTPTS" ]; then
	TEXTPTS=24
fi

# The colour (sic) of the text
# https://www.ffmpeg.org/ffmpeg-utils.html#Color
# the names seem to be the old X11 names.
if [ -z "$TEXTCOLOR" ]; then
	TEXTCOLOR=white
fi

# set the text in the middle of the screen, using example from man 1 ffmpeg-filters
# sometimes, a different value of y might be more useful
#TEXTPOSITION="x=(w-text_w)/2:y=(h-text_h-line_h)/2"
# this version puts it nearer the bottom
TEXTPOSITION="x=(w-text_w)/2:y=(h-text_h-line_h)*3/4"

usage() {
	if [ "$MYSELF" = "video-single.sh" ]; then
		echo "process a video file (tested for .mov) to .mkv with aac audio and"
		echo "x264 video, via intermediate wav audio, for publication on youtube"
	else
		echo "process a video file (tested for .mov) to .mkv with wav audio and"
		echo "x264 video, for later merging with other files"
	fi
	echo "via mp4 and wav files, using ffmpeg and sox"
	echo
	echo "all parms are in the form name=\"value\""
	echo "Required parms:"
	echo "infile= : the input file to process"
	echo "outstem= : the main part of the filename for output files"
	echo "          (wav files get a suffix.wav, others are .mp4 and .mkv"
	echo "optional parms:"
	echo "afade= : audio fade parameter(s) to pass to sox"
	echo "crf- : change the Constant Rate Factor value in ffmpeg's x264 encoding,"
	echo "       from the default of $CRF"
	echo "start= : offset from which to process"
	echo "        (the result may be approximate if  that point is not a key frame)"
	echo "time= : duration of output"
	if [ "$MYSELF" = "video-single.sh" ]; then
		echo "title= : title for the video"
	fi
	echo "vfi= : (video fade-in - frame_no:frame_count"
	echo " NB frame_no is re the original input file, that matters if you specify start="
	echo "vfo= : (video fade-out - frame_no:frame_count"
	echo "vol= : audio volume, 3 digits, normal is 255"
	echo "text= : if ffmpeg has been compiled using --enable-libfreetype, show this"
	echo "       text in white, 24pt DejaVu Sans, in the centre of the picture."
	exit 2
}

if [ $# -lt 2 ]; then
	echo "ERROR: insufficient parameters"
	usage
	exit 1
fi

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
	if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
		return 0
	else
		return 1
	fi

	#shopt -u nocasematch
}

# functions for handling the various input parameters:
process-afade () {
# although sox does not REQUIRE the 'type' (shape),
# it make sense to enforce it here.
# follow by fade-in-length in seconds (might be zero)
# optionally stop-time - warn if not 0 i.e end of file
# fade-out-length if not same as fade-in-length
	FIELDS=$(echo $RHS | awk '{ print NF }')
	if [ $FIELDS -lt 2 ]; then
		echo "ERROR: afade requires at least two fields"
		exit 1
	fi
	# REQUIRE a type field - it is technically optional in sox
	F1=$(echo $RHS | awk '{ print $1 }')
	case "$F1" in
		q|h|t|l|p)
			true
			;;
		*)
			echo "ERROR: afade type MUST be specified for this wrapper"
			echo "but the supplied value was $F1"
			exit 1
		;;
	esac
	F2=$(echo $RHS | awk '{ print $2 }')
	# check if numeric - whole seconds
	FDIGITS=$(echo "$F2" | pcregrep '\d+')
	if ! [ "$FDIGITS" = "$F2" ]; then
		echo "ERROR: afade fade-in length in not numeric"
		exit 1
	fi
	if [ $FIELDS -ge 3 ]; then
		F3=$(echo $RHS | awk '{ print $3 }')
		# any third field must be numeric
		FDIGITS=$(echo "$F3" | pcregrep '\d+')
		if ! [ "$FDIGITS" = "$F3" ]; then
			echo "ERROR: afade stop-time (in seconds) is not numeric"
			exit 1
		fi
	fi
	if [ $FIELDS -ge 4 ]; then
		F4=$(echo $RHS | awk '{ print $4 }')
		# any fourth field must be numeric
		FDIGITS=$(echo "$F4" | pcregrep '\d+')
		if ! [ "$FDIGITS" = "$F4" ]; then
			echo "ERROR: afade fade-out-length is not numeric"
			exit 1
		fi
	fi
	if [ $FIELDS -gt 4 ]; then
		echo "ERROR: too many fields for afade"
		echo "use type fade-in-length (stop-time) (fade-out-length)"
		exit 1
	fi
	# if ok, store $RHS
	AFADEVAL=$RHS
}


process-crf () {
	NEWCRF=$RHS
	if ! [ "$NEWCRF" -eq "$RHS" ] 2>/dev/null; then
		echo "ERROR: crf requires a numeric value"
		exit 1
	fi
	echo "changing crf from $CRF to $NEWCRF"
	CRF=$NEWCRF
}

process-infile () {
INFILE=$RHS
if ! [ -f $INFILE ]; then
	echo "Error: input file $INFILE not found."
	exit 2
else
	IDURATION=$(ffprobe $INFILE 2>&1 | grep 'Duration:' | awk '{ print $2 }' | sed 's/,//')
	#echo IDURATION begins as $IDURATION
	# a value of 00:00:08.00 caused bash's shell arithmetic to blow up,
	# because 08 was treated as invalid octal.
	# so strip any leading zeroes from the parts.
	IDURATION=$(echo $IDURATION | sed -e 's/:0/:/g' -e's/^00/0/')
	#echo IDURATION becomes $IDURATION
	IVFRAMES=$(ffprobe -select_streams v -show_streams $INFILE 2>&1 | grep 'nb_frames' | \
	 cut -d '=' -f 2)
	if [ "$IVFRAMES" = "N/A" ] || [ -z "$IVFRAMES" ]; then
		echo "ERROR: is $INFILE a valid video file?"
		exit 2
	fi
	echo "will process $INFILE which has a duration of $IDURATION and $IVFRAMES video frames"
	# now calculate time for the input file (seconds, decimals)
	# and then work out the frames per second : call check-time to set $SECONDSDEC.
	check-time $IDURATION
	INUM=$SECONDSDEC
	# this was originally to one decimal place, in case it ever came out as 29.9
	# but for the moment it seems to always be 30.on my camera
	#FPS=$(echo "$IVFRAMES /  $INUM" | bc -l | sed 's/\(.*\..\).*/\1/')
	FPS=$(echo "$IVFRAMES /  $INUM" | bc )
	if [ "$FPS" -ne "$MYFPS" ]; then
		echo "unexpected frames per second, $FPS not $MYFPS - review calculation"
		exit 2
	fi
	# set expected frames, in case time= is not provided
	# but if already set, use that : buggy if two different input=
	# files are specified, but that can be blamed on the user.
	if [ -z "$EXPECTEDFRAMES" ]; then
		EXPECTEDFRAMES=$IVFRAMES
	fi
fi
}

process-outstem () {
OSTEM=$RHS
if [ -f $OSTEM.mp4 ]; then
	echo "WARNING: $OSTEM.mp4 exists : this has already run, at least in part"
	let WARN=$WARN+1
else
	touch $OSTEM.tmp
	if [ $? -ne 0 ]; then
		echo "ERROR: output file stem name seems to be invalid"
		usage
	else
		rm $OSTEM.tmp
		echo "output stem will be \"$OSTEM\""
	fi
fi
}

process-start () {
	check-time $RHS
	if [ "$SECONDSDEC" = "0." ]; then
		echo "NOTE: start=0 is the default"
	else
		STARTVAL="$RHS"
		STARTNUM="$SECONDSDEC"
		# this script takes a simple approach.
		# what is requested might not be a key frame
		echo "WARNING: timings with 'start' may be approximate"
		let WARN=$WARN+1
	fi
}

process-text () {
	# check that ffmpeg was compiled against libfreetype (so that the drawtext
	# video filter will work), find the path to DejaVu Sans using fc-list,
	# unless $TEXTFONT has been set
	# and then set up the text.  This is for a caption, but it will apply to
	# the whole video (for me, it is easiest to copy the original to three
	# parts : before caption, with caption, after caption : and then process
	# them individually.  NB text is always white 24 pt unless TEXTCOLOR and/or
	# TEXTSIZE are set or exported to this script.  TEXTPOSITION is hardcoded
	# above.

	# confirm ffmpeg is linked against libfreetype, I did not used to bother
	# doing that.  NB 'ffmpeg -filters | grep drawtext' produces unmanageable
	# output on both stdout and stderr, but might work cleanly in a subshell.
	ldd $(which ffmpeg) | grep -q freetype
	if [ $? -ne 0 ]; then
		echo "ERROR : text= was specified, but ffmpeg was not built against libfreetype"
		exit 1
	fi
	if [ -z "$TEXTFONT" ]; then
		TEXTFONT=$(fc-list | grep 'DejaVu Sans:style=Book' | cut -d ':' -f 1)
		if [ -z "$TEXTFONT" ]; then
			echo "ERROR: please set TEXTFONT to point to your desired ttf or otf font"
		fi
	fi
	# things break at any spaces in the text, using the values of variables containing
	# double quotes for the video filter settings is beyond me!
	# so change to non break space - I used rxvt-unicode to key in U+00A0 here
	TEXTTEXT=$(echo $RHS | sed 's/ / /g' )
	#echo $TEXTTEXT | grep ' ' && echo "changed space to non break space U+00A0" || echo "FAIL"
	DRAWTEXT="drawtext=fontsize=${TEXTPTS}:fontfile=${TEXTFONT}:fontcolor=${TEXTCOLOR}:text=${TEXTTEXT}:${TEXTPOSITION}"
}

process-time () {
	check-time $RHS
	TIMEVAL="$RHS"
	TIMENUM="$SECONDSDEC"
	EXPECTEDFRAMES=$(echo "$TIMENUM * $FPS" | bc)
	echo "expected output frame total is $EXPECTEDFRAMES"
}

process-title () {
	TITLESTR=$(echo $RHS | sed 's/ / /g' )
	TITLE="-metadata title=\"$TITLESTR\""
	if [ "$MYSELF" != "video-single.sh" ]; then
		echo "WARNING: specifying a title for $MYSELF is silly"
		let WARN=$WARN+1
	fi
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

process-vol () {
	# volume should be exactly 3 digits
	VOLDIGITS=$(echo "$RHS" | pcregrep '\d\d\d')
	if [ "$VOLDIGITS" != "$RHS" ]; then
		echo "ERROR: vol= requires 3 digits"
		exit 1
	fi
	BCVAR=$(echo "$VOLDIGITS < 255" | bc)
	if [ "$BCVAR" = "1" ]; then
		echo "reducing volume to $VOLDIGITS"
	else
		BCVAR=$(echo "$VOLDIGITS > 255" | bc)
		if [ "$BCVAR" = "1" ]; then
			echo "INCREASING volume to $VOLDIGITS"
		fi
	fi
	VOL="-vol $VOLDIGITS"
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
		afade)
			process-afade
			;;
		crf)
			process-crf
			;;
		infile)
			process-infile
			;;
		outstem)
			process-outstem
			;;
		start)
			process-start
			;;
		text)
			process-text
			;;
		time)
			process-time
			;;
		title)
			process-title
			;;
		vfi)
			process-vfi
			;;
		vfo)
			process-vfo
			;;
		vol)
			process-vol
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

if [ -z "$OSTEM" ]; then
	echo "ERROR: outstem= was not supplied"
	usage
fi

# compare the values, as appropriate
# 1. if TIMENUM exists, it should not exceed INUM
if [ -n "$TIMENUM" ]; then
	# NB remember that bc returns '1' if a comparison is true
	BCVAR=$(echo "$TIMENUM > $INUM" | bc)
	if [ "$BCVAR" = "1" ]; then
		echo "WARNING: requested time $TIMENUM seconds longer than input file $INUM"
		let WARN=$WARN+1
	fi
	# if time and start were specified, do a similar check but adding them
	if [ -n "$STARTNUM" ]; then
		BCVAR=$(echo "($STARTNUM + $TIMENUM) > $INUM" | bc)
		if [ "$BCVAR" = "1" ]; then
			echo "WARNING: requested start offset + time longer than input file"
			let WARN=$WARN+1
		fi
	fi
fi

# 2. if both vfi and vfo were specified, vfi SHOULD finish before vfo
# NB if STARTNUM was specified, vfi might be before the part we process
# because it seems to be relative to the _input_ file.
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
if [ -n "$STARTVAL" ]; then
	START="-ss $STARTVAL"
	echo "will use a start value of $START"
fi
if [ -n "$TIMEVAL" ]; then
	TIME="-t $TIMEVAL"
	echo "will use a duration of $TIME"
fi

# For captions using drawtext, they not only occupy the whole clip, they
# are also fully visible while fading in oor out.
if [ -n "$iDRAWTEXT" ]; then
	if [ -n "$VFISTART" ] || [ -n "$VFOSTART" ]; then
		echo "WARNING: drawtext will display text across the video fade(s)"
		let WARN=$WARN+1
	fi
fi

# for vfade, if both exist then they need to be separated by a comma
if [ -n "$VFISTART" ] || [ -n "$DRAWTEXT" ] || [ -n "$VFOSTART" ]; then
	# start the video fade command
	#VFCMD="-vf \""		
	# for some reason, although this works in double quotes when I
	# run it by hand, it does not work when ffmpeg is invoked from
	# the script, but is ok without quoting.
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
	# if DRAWTEXT also set, add a comma
	if ! [ -n "DRAWTEXT" ]; then
		VFCMD="${VFCMD},"
	fi
fi
if [ -n "$DRAWTEXT" ]; then
	VFCMD="${VFCMD}${DRAWTEXT}"
fi
if [ -n "$VFISTART" ] || [ -n "$VFOSTART" ] || [ -n "$DRAWTEXT" ]; then
	# close the video filter command
	#VFCMD="${VFCMD}\""	
	# same comment on quoting as for the start of VFCMD
	VFCMD="${VFCMD}"
fi
if [ -n "$VFCMD" ]; then
	echo "will set video filter to $VFCMD"
fi

if [ -n "$AFADEVAL" ]; then
	AFADE="fade $AFADEVAL"
	echo "will pass $AFADE to sox to fade the audio"
fi


if [ $WARN -gt 0 ]; then
	if [ $WARN -eq 1 ]; then
		echo "*** there was 1 Warning ***"
	else
		echo "** there were $WARN warnings ***"
	fi
fi

# perhaps ought to show the commands anyway ?
# now bring the parts back together

# debugging
echo "volume command is $VOL"
echo "CRF is $CRF"
echo "AUDIO is $AUDIO"
echo "$MERGEMSG"

yorn
if [ $? -ne 0 ]; then
	echo "abandonned"
	exit 0
fi

# Now, run these wonderful commands!

STARTTIME=$SECONDS
# first create an mp4
echo "creating $OSTEM.mp4"
# crf 22, without preset other than the default medium, and without video
# buffer, seems to do the job adequately, and quickly : the output is
# comparatively large, but that seems to be down to using crf.  For a
# final file which is to be uplaoded, crf 24 or 25 are a lot smaller.
# if you uncomment the echo, add a '"' at the end of the command	
# $VFCMD could also be after crf 22, the result seems identical
#echo "command will be
ffmpeg -i $INFILE $START $TIME -s $MYPIXELS $VFCMD  -vcodec libx264 -crf $CRF \
 $AAC -y ${OSTEM}.mp4

if ! [ -f ${OSTEM}.mp4 ]; then
	echo "initial encoding failed"
	exit 2
fi

echo "creating $OSTEMbase.wav"
ffmpeg -i $INFILE $START $TIME -acodec pcm_s16le $VOL -y ${OSTEM}base.wav

if [ $? -ne 0 ]; then
	echo "creation of ${OSTEM}base.wav failed"
	exit 2
fi

if [ -n "$AFADE" ]; then
	MIXWAV=${OSTEM}fade.wav
	echo "creating ${OSTEM}fade.wav"
	sox ${OSTEM}base.wav ${OSTEM}fade.wav $AFADE
	if [ $? -ne 0 ]; then
		echo "creation of ${OSTEM}fade.wav failed"
		exit 2
	fi

else
	MIXWAV=${OSTEM}base.wav
fi

echo $MERGEMSG
ffmpeg -i ${OSTEM}.mp4 -i $MIXWAV -map 0:0 -map 1:0 \
 -c:v copy ${AUDIO} ${TITLE} -y ${OSTEM}.mkv

if [ $? -eq 0 ]; then
	echo "created ${OSTEM}.mkv"
fi
ENDTIME=$SECONDS
let ELAPSED=$ENDTIME-$STARTTIME
let EHH=$ELAPSED/3600
let ELAPSED=$ELAPSED%3600
let EMM=$ELAPSED/60
let ELAPSED=$ELAPSED%60
echo "Creating the files took approx $EHH:$EMM:$ELAPSED"
