#!/bin/sh

##
## Initialize some basic useful stuff.
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

logtstart "basic"

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi

. $OURDIR/admin-openrc.sh

#
# Fork off a bunch of parallelizable tasks, then do some misc stuff,
# then wait.
#
echo "*** Backgrounding quota setup..."
$DIRNAME/setup-basic-quotas.sh  >> $OURDIR/setup-basic-quotas.log 2>&1 &
quotaspid=$!
echo "*** Backgrounding network setup..."
$DIRNAME/setup-basic-networks.sh  >> $OURDIR/setup-basic-networks.log 2>&1 &
networkspid=$!
echo "*** Backgrounding user setup..."
$DIRNAME/setup-basic-users.sh  >> $OURDIR/setup-basic-users.log 2>&1 &
userspid=$!

. $DIRNAME/setup-images-lib.sh
$LOCKFILE $IMAGESETUPLOCKFILE
if [ -f $IMAGEUPLOADCMDFILE ]; then
    echo "*** Adding Images ..."
    . $OURDIR/admin-openrc.sh
    . $IMAGEUPLOADCMDFILE
fi
$RMLOCKFILE $IMAGESETUPLOCKFILE

ARCH=`uname -m`
if [ "$ARCH" = "aarch64" ] ; then
    echo "*** Doing aarch64-specific setup..."
    $DIRNAME/setup-basic-aarch64.sh
else
    echo "*** Doing x86_64-specific setup..."
    $DIRNAME/setup-basic-x86_64.sh
fi

for pid in "$quotaspid $networkspid $userspid" ; do
    wait $pid
done

logtend "basic"

exit 0
