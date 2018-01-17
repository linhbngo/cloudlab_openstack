#!/bin/sh

##
## Download, configure, and upload one or more images into Glance.
##

if [ -n "$DEBUG" -a ! $DEBUG -eq 0 ]; then
    set -x
fi

DIRNAME=`dirname $0`

# Gotta know the rules!
if [ `id -u` -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

force=0
if [ "$1" = "--force" ]; then
    force=1
    shift
fi
CUSTOMIMAGEURLS=""
while [ -n "$1" ]; do
    CUSTOMIMAGEURLS="$CUSTOMIMAGEURLS $1"
    shift
done
if [ -z "$CUSTOMIMAGEURLS" ]; then
    echo "*** ERROR: you didn't specify an image URL to import!"
    exit 1
fi

# Grab our libs
. "$DIRNAME/setup-lib.sh"
. "$DIRNAME/setup-images-lib.sh"

if [ "$HOSTNAME" != "$CONTROLLER" ]; then
    exit 1;
fi

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi

. $OURDIR/admin-openrc.sh

if [ ! -f $OURDIR/controller-done ]; then
    echo "*** ERROR: your controller is still being configured; wait until it's done (until $OURDIR/controller-done exists; check $OURDIR/setup-controller.log to check progress)"
    exit 1
fi

#
# Take our lockfile.
#
echo "*** Getting image lock..."
$LOCKFILE $IMAGESETUPLOCKFILE
echo "*** Got image lock, continuing..."

cwd=`pwd`
cd $IMAGEDIR

if [ -n "$CUSTOMIMAGEURLS" ]; then
    for imgurl in $CUSTOMIMAGEURLS ; do
	echo "$imgurl" | grep -q '|'
	if [ $? -eq 0 ]; then
	    imgurl=`echo "$imgurl" | cut -f 1 -d '|'`
	    imgname=`echo "$imgurl" | cut -f 2 -d '|'`
	fi

	imgfile=`get_url "$imgurl"`
	if [ ! $? -eq 0 ]; then
	    echo "ERROR: could not download $imgurl !"
	else
	    if [ -z "$imgname" ]; then
		imgname=`echo $imgfile | sed -e 's/\([^\.]*\)\..*$/\1/'`
	    fi
	    imgfile=`extract_image "$imgfile"`
	    if [ -n "$imgfile" ]; then
		(fixup_image "$imgfile" \
		    && upload_image "$IMAGEDIR/$imgfile" "$imgname") \
		 || echo "ERROR: could not configure and upload user VM image $imgurl !"
	    else
		echo "ERROR: could not extract user VM image $imgurl !"
	    fi
	fi
    done
fi

#
# Release our lockfile.
#
echo "*** Releasing image lock..."
$RMLOCKFILE $IMAGESETUPLOCKFILE
echo "*** Released image lock."

exit 0
