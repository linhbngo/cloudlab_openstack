#!/bin/sh

##
## Download and configure some images, and write out glance commands to
## get them uploaded into glance.  This script only runs the upload
## commands if we're not being run from controller setup; otherwise, the
## controller setup process runs this when it is safe (if in controller
## setup, we don't upload them into glance immediately because glance
## might not be running or any number of components may be restarting or
## otherwise in flux; setup-basic.sh uploads them when it is safe, near
## the end of our setup).
##

set -x

DIRNAME=`dirname $0`

# Gotta know the rules!
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Grab our libs
. "$DIRNAME/setup-lib.sh"

if [ "$HOSTNAME" != "$CONTROLLER" ]; then
    exit 0;
fi

logtstart "images"

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi

. $DIRNAME/setup-images-lib.sh

#
# Take our lockfile.
#
$LOCKFILE $IMAGESETUPLOCKFILE

#
# Create and truncate our upload commands.
#
truncate -s 0 $IMAGEUPLOADCMDFILE
chmod 755 $IMAGEUPLOADCMDFILE

cwd=`pwd`
cd $IMAGEDIR

#
# Setup the per-arch default images (and let them override our default
# *_image functions if they wish).
#
if [ "$ARCH" = "aarch64" ] ; then
    . $DIRNAME/setup-images-aarch64.sh
else
    . $DIRNAME/setup-images-x86_64.sh
fi

if [ -n "$EXTRAIMAGEURLS" ]; then
    for imgurl in $EXTRAIMAGEURLS ; do
	imgname=""
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
		    && sched_image "$IMAGEDIR/$imgfile" "$imgname") \
		 || echo "ERROR: could not download user VM image $imgurl !"
	    else
		echo "ERROR: could not extract user VM image $imgurl !"
	    fi
	fi
    done
fi

#
# If we're not in controller setup, or if the controller has already
# run, do the uploads now.
#
#if [ -f $OURDIR/controller-done ]; then
#    . $OURDIR/admin-openrc.sh
#    . $IMAGEUPLOADCMDFILE
#fi

#
# Release our lockfile.
#
$RMLOCKFILE $IMAGESETUPLOCKFILE

logtend "images"

exit 0
