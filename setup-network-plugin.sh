#!/bin/sh

##
## Setup a OpenStack node to run whichever ML2 plugin we're configured to run.
##

set -x

# Gotta know the rules!
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Grab our libs
. "`dirname $0`/setup-lib.sh"

if [ -f $OURDIR/setup-network-plugin-done ]; then
    exit 0
fi

logtstart "network-plugin"

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi
if [ -f $LOCALSETTINGS ]; then
    . $LOCALSETTINGS
fi

if [ "${ML2PLUGIN}" = "linuxbridge" ]; then
    $DIRNAME/setup-network-plugin-linuxbridge.sh
else
    $DIRNAME/setup-network-plugin-openvswitch.sh
fi

if [ $? -eq 0 ]; then
    touch $OURDIR/setup-network-plugin-done
    logtend "network-plugin"
    exit 0
else
    err=$?
    logtend "network-plugin"
    exit $err
fi
