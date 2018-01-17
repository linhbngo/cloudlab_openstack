#!/bin/sh

##
## Setup a OpenStack Storage Node for Telemetry
##

set -x

# Gotta know the rules!
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Grab our libs
. "`dirname $0`/setup-lib.sh"

if [ "$HOSTNAME" != "$STORAGEHOST" ]; then
    exit 0;
fi

if [ -f $OURDIR/setup-storage-telemetry-done ]; then
    exit 0
fi

logtstart "storage-telemetry"

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi


crudini --set /etc/cinder/cinder.conf DEFAULT control_exchange cinder
if [ $OSVERSION -lt $OSMITAKA ]; then
    crudini --set /etc/cinder/cinder.conf DEFAULT notification_driver messagingv2
else
    crudini --set /etc/cinder/cinder.conf oslo_messaging_notifications driver messagingv2
fi
#notification_driver = cinder.openstack.common.notifier.rpc_notifier

if [ -x /usr/bin/cinder-volume-usage-audit ]; then
    echo "*/5 * * * * /usr/bin/cinder-volume-usage-audit --send_actions" >> /etc/crontab
fi

service_restart cinder-volume
service_enable cinder-volume

touch $OURDIR/setup-storage-telemetry-done

logtend "storage-telemetry"

exit 0
