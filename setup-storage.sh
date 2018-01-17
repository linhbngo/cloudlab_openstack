#!/bin/sh

##
## Setup a OpenStack compute node for Nova.
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

if [ -f $OURDIR/setup-storage-host-done ]; then
    exit 0
fi

logtstart "storage"

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi
if [ -f $LOCALSETTINGS ]; then
    . $LOCALSETTINGS
fi

ARCH=`uname -m`

maybe_install_packages lvm2
if [ $OSVERSION -ge $OSOCATA ]; then
    maybe_install_packages thin-provisioning-tools
fi

#
# First try to make LVM volumes; fall back to loop device in /storage.  We use
# /storage for swift later, so we make the dir either way.
#

mkdir -p /storage
if [ -z "$LVM" ] ; then
    LVM=1
    VGNAME="openstack-volumes"
    MKEXTRAFS_ARGS="-l -v ${VGNAME} -m util -z 1024"
    # On Cloudlab ARM machines, there is no second disk nor extra disk space
    # Well, now there's a new partition layout; try it.
    if [ "$ARCH" = "aarch64" ]; then
	maybe_install_packages gdisk
	sgdisk -i 1 /dev/sda
	if [ $? -eq 0 ] ; then
	    sgdisk -N 2 /dev/sda
	    partprobe /dev/sda
	    if [ $? -eq 0 ] ; then
		partprobe /dev/sda
		# Add the second partition specifically
		MKEXTRAFS_ARGS="${MKEXTRAFS_ARGS} -s 2"
	    else
		MKEXTRAFS_ARGS=""
		LVM=0
	    fi
	else
	    MKEXTRAFS_ARGS=""
	    LVM=0
	fi
    fi

    /usr/local/etc/emulab/mkextrafs.pl ${MKEXTRAFS_ARGS}
    if [ $? -ne 0 ]; then
	/usr/local/etc/emulab/mkextrafs.pl ${MKEXTRAFS_ARGS} -f
	if [ $? -ne 0 ]; then
	    /usr/local/etc/emulab/mkextrafs.pl -f /storage
	    LVM=0
	fi
    fi
fi

if [ $LVM -eq 0 ] ; then
    dd if=/dev/zero of=/storage/pvloop.1 bs=32768 count=131072
    LDEV=`losetup -f`
    losetup $LDEV /storage/pvloop.1

    pvcreate /dev/loop0
    vgcreate $VGNAME /dev/loop0
fi

maybe_install_packages cinder-volume $DBDPACKAGE

crudini --set /etc/cinder/cinder.conf \
    database connection "${DBDSTRING}://cinder:$CINDER_DBPASS@$CONTROLLER/cinder"

crudini --del /etc/cinder/cinder.conf keystone_authtoken auth_host
crudini --del /etc/cinder/cinder.conf keystone_authtoken auth_port
crudini --del /etc/cinder/cinder.conf keystone_authtoken auth_protocol

crudini --set /etc/cinder/cinder.conf DEFAULT auth_strategy keystone
crudini --set /etc/cinder/cinder.conf DEFAULT verbose ${VERBOSE_LOGGING}
crudini --set /etc/cinder/cinder.conf DEFAULT debug ${DEBUG_LOGGING}
crudini --set /etc/cinder/cinder.conf DEFAULT my_ip ${MGMTIP}

if [ $OSVERSION -lt $OSKILO ]; then
    crudini --set /etc/cinder/cinder.conf DEFAULT rpc_backend rabbit
    crudini --set /etc/cinder/cinder.conf DEFAULT rabbit_host $CONTROLLER
    crudini --set /etc/cinder/cinder.conf DEFAULT rabbit_userid ${RABBIT_USER}
    crudini --set /etc/cinder/cinder.conf DEFAULT rabbit_password "${RABBIT_PASS}"
elif [ $OSVERSION -lt $OSNEWTON ]; then
    crudini --set /etc/cinder/cinder.conf DEFAULT rpc_backend rabbit
    crudini --set /etc/cinder/cinder.conf oslo_messaging_rabbit \
	rabbit_host $CONTROLLER
    crudini --set /etc/cinder/cinder.conf oslo_messaging_rabbit \
	rabbit_userid ${RABBIT_USER}
    crudini --set /etc/cinder/cinder.conf oslo_messaging_rabbit \
	rabbit_password "${RABBIT_PASS}"
else
    crudini --set /etc/cinder/cinder.conf DEFAULT transport_url $RABBIT_URL
fi

if [ $OSVERSION -lt $OSKILO ]; then
    crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	auth_uri http://${CONTROLLER}:5000/${KAPISTR}
    crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	identity_uri http://${CONTROLLER}:35357
    crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	admin_tenant_name service
    crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	admin_user cinder
    crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	admin_password "${CINDER_PASS}"
else
    crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	auth_uri http://${CONTROLLER}:5000
    crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	auth_url http://${CONTROLLER}:35357
    crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	${AUTH_TYPE_PARAM} password
    crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	${PROJECT_DOMAIN_PARAM} default
    crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	${USER_DOMAIN_PARAM} default
    crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	project_name service
    crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	username cinder
    crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	password "${CINDER_PASS}"
fi

crudini --set /etc/cinder/cinder.conf DEFAULT glance_host ${CONTROLLER}
if [ $OSVERSION -ge $OSMITAKA ]; then
    crudini --set /etc/cinder/cinder.conf \
	glance api_servers http://${CONTROLLER}:9292
fi

if [ $OSVERSION -eq $OSKILO ]; then
    crudini --set /etc/cinder/cinder.conf oslo_concurrency \
	lock_path /var/lock/cinder
elif [ $OSVERSION -ge $OSLIBERTY ]; then
    crudini --set /etc/cinder/cinder.conf oslo_concurrency \
	lock_path /var/lib/cinder/tmp
fi

if [ $OSVERSION -eq $OSJUNO ]; then
    crudini --set /etc/cinder/cinder.conf DEFAULT volume_group openstack-volumes
else
    crudini --set /etc/cinder/cinder.conf lvm \
	volume_driver cinder.volume.drivers.lvm.LVMVolumeDriver
    crudini --set /etc/cinder/cinder.conf lvm volume_group openstack-volumes
    crudini --set /etc/cinder/cinder.conf lvm iscsi_protocol iscsi
    crudini --set /etc/cinder/cinder.conf lvm iscsi_helper tgtadm
    crudini --set /etc/cinder/cinder.conf DEFAULT enabled_backends lvm
fi

service_restart tgt
service_enable tgt
service_restart cinder-volume
service_enable cinder-volume
rm -f /var/lib/cinder/cinder.sqlite

echo "LVM=$LVM" >> $LOCALSETTINGS
echo "VGNAME=${VGNAME}" >> $LOCALSETTINGS

touch $OURDIR/setup-storage-host-done

logtend "storage"

exit 0
