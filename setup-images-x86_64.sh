#!/bin/sh

##
## Download and configure the default x86_64 images.
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

logtstart "images-x86_64"

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi

cd $IMAGEDIR

echo "*** Configuring a trusty-server x86_64 image ..."
imgfile=trusty-server-cloudimg-amd64-disk1.img
imgname=trusty-server
#
# First try the local boss, then Apt, then just grab from Ubuntu.
#
imgfile=`get_url "http://boss.${OURDOMAIN}/downloads/openstack/$imgfile http://boss.apt.emulab.net/downloads/openstack/$imgfile https://cloud-images.ubuntu.com/trusty/current/$imgfile"`
if [ ! $? -eq 0 ]; then
    echo "ERROR: failed to download $imgfile from Cloudlab or Ubuntu!"
else
    old="$imgfile"
    imgfile=`extract_image "$imgfile"`
    if [ ! $? -eq 0 ]; then
	echo "ERROR: failed to extract $old"
    else
	(fixup_image "$imgfile" \
	    && sched_image "$IMAGEDIR/$imgfile" "$imgname" ) \
	    || echo "ERROR: could not configure default VM image $imgfile !"
    fi
fi

#
# Setup the Manila service image so that Manila works out of the box.
#
echo "*** Configuring the manila-service-image image ..."
imgfile=manila-service-image-master.qcow2
imgname=manila-service-image
imgfile=`get_url "http://boss.${OURDOMAIN}/downloads/openstack/$imgfile http://boss.apt.emulab.net/downloads/openstack/$imgfile http://tarballs.openstack.org/manila-image-elements/images/$imgfile"`
if [ ! $? -eq 0 ]; then
    echo "ERROR: failed to download $imgfile from Cloudlab or Ubuntu!"
else
    old="$imgfile"
    imgfile=`extract_image "$imgfile"`
    if [ ! $? -eq 0 ]; then
	echo "ERROR: failed to extract $old"
    else
	(fixup_image "$imgfile" \
	    && sched_image "$IMAGEDIR/$imgfile" "$imgname" ) \
	    || echo "ERROR: could not configure default VM image $imgfile !"
    fi
fi

#    glance image-create --name manila-service-image --file $imgfile \
#	--disk-format qcow2 --container-format bare --progress \
#	--visibility public


#
# NB: do not exit; we are included!
#

logtend "images-x86_64"
