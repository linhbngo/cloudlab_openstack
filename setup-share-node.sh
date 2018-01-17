#!/bin/sh

##
## Setup a OpenStack share node for Manila.
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

if [ "$HOSTNAME" != "$SHAREHOST" ]; then
    exit 0;
fi

if [ -f $OURDIR/setup-share-host-done ]; then
    exit 0
fi

logtstart "share-node"

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi
if [ -f $LOCALSETTINGS ]; then
    . $LOCALSETTINGS
fi

#
# We need whatever Neutron ML2 plugin we're supposed to use, on this node.
#
$DIRNAME/setup-network-plugin.sh

maybe_install_packages manila-share $DBDPACKAGE

crudini --set /etc/manila/manila.conf \
    database connection "${DBDSTRING}://manila:$MANILA_DBPASS@$CONTROLLER/manila"

crudini --del /etc/manila/manila.conf keystone_authtoken auth_host
crudini --del /etc/manila/manila.conf keystone_authtoken auth_port
crudini --del /etc/manila/manila.conf keystone_authtoken auth_protocol

crudini --set /etc/manila/manila.conf DEFAULT auth_strategy keystone
crudini --set /etc/manila/manila.conf DEFAULT verbose ${VERBOSE_LOGGING}
crudini --set /etc/manila/manila.conf DEFAULT debug ${DEBUG_LOGGING}
crudini --set /etc/manila/manila.conf DEFAULT my_ip ${MGMTIP}
crudini --set /etc/manila/manila.conf DEFAULT \
    default_share_type default_share_type
crudini --set /etc/manila/manila.conf DEFAULT \
    rootwrap_config /etc/manila/rootwrap.conf

if [ $OSVERSION -lt $OSNEWTON ]; then
    crudini --set /etc/manila/manila.conf DEFAULT rpc_backend rabbit
    crudini --set /etc/manila/manila.conf oslo_messaging_rabbit \
	rabbit_host $CONTROLLER
    crudini --set /etc/manila/manila.conf oslo_messaging_rabbit \
	rabbit_userid ${RABBIT_USER}
    crudini --set /etc/manila/manila.conf oslo_messaging_rabbit \
	rabbit_password "${RABBIT_PASS}"
else
    crudini --set /etc/manila/manila.conf DEFAULT transport_url $RABBIT_URL
fi
crudini --set /etc/manila/manila.conf keystone_authtoken \
    memcached_servers ${CONTROLLER}:11211
crudini --set /etc/manila/manila.conf keystone_authtoken \
    auth_uri http://${CONTROLLER}:5000
crudini --set /etc/manila/manila.conf keystone_authtoken \
    auth_url http://${CONTROLLER}:35357
crudini --set /etc/manila/manila.conf keystone_authtoken \
    ${AUTH_TYPE_PARAM} password
crudini --set /etc/manila/manila.conf keystone_authtoken \
    ${PROJECT_DOMAIN_PARAM} default
crudini --set /etc/manila/manila.conf keystone_authtoken \
    ${USER_DOMAIN_PARAM} default
crudini --set /etc/manila/manila.conf keystone_authtoken \
    project_name service
crudini --set /etc/manila/manila.conf keystone_authtoken \
    username manila
crudini --set /etc/manila/manila.conf keystone_authtoken \
    password "${MANILA_PASS}"

crudini --set /etc/manila/manila.conf oslo_concurrency \
    lock_path /var/lib/manila/tmp

#
# Setup the share node details:
#
maybe_install_packages lvm2 nfs-kernel-server

if [ "$MANILADRIVER" = "lvm" ]; then
    #
    # First try to make LVM volumes; fall back to loop device in /storage.  We use
    # /storage for swift later, so we make the dir either way.
    #
    mkdir -p /storage
    if [ -z "$MNLVM" ] ; then
	MNLVM=1
	MNVGNAME="manila-volumes"
	MKEXTRAFS_ARGS="-l -v ${MNVGNAME}" # -m util -z 1G"
        # On Cloudlab ARM machines, there is no second disk nor extra disk space
        # Well, now there's a new partition layout; try it.
	if [ "$ARCH" = "aarch64" ]; then
	    sgdisk -i 1 /dev/sda
	    if [ $? -eq 0 ] ; then
		sgdisk -N 2 /dev/sda
		if [ $? -eq 0 ] ; then
		    partprobe
    		    # Add the second partition specifically
		    MKEXTRAFS_ARGS="${MKEXTRAFS_ARGS} -s 2"
		else
		    MKEXTRAFS_ARGS=""
		    MNLVM=0
		fi
	    else
		MKEXTRAFS_ARGS=""
		MNLVM=0
	    fi
	fi
	
	/usr/local/etc/emulab/mkextrafs.pl ${MKEXTRAFS_ARGS}
	if [ $? -ne 0 ]; then
	    /usr/local/etc/emulab/mkextrafs.pl ${MKEXTRAFS_ARGS} -f
	    if [ $? -ne 0 ]; then
		/usr/local/etc/emulab/mkextrafs.pl -f /storage
		MNLVM=0
	    fi
	fi
    fi

    if [ $MNLVM -eq 0 ] ; then
	dd if=/dev/zero of=/storage/pvloop.2 bs=32768 count=131072
	LDEV=`losetup -f`
	losetup $LDEV /storage/pvloop.2
	
	pvcreate $LDEV
	vgcreate $MNVGNAME $LDEV
    fi

    echo "MNLVM=$MNLVM" >> $LOCALSETTINGS
    echo "MNVGNAME=${MNVGNAME}" >> $LOCALSETTINGS
fi

if [ "$MANILADRIVER" = "lvm" ]; then
    # XXX: add LVM devices { filter ... } to /etc/lvm/lvm.conf ...
    crudini --set /etc/manila/manila.conf DEFAULT enabled_share_backends lvm
    crudini --set /etc/manila/manila.conf DEFAULT enabled_share_protocols NFS,CIFS

    crudini --set /etc/manila/manila.conf lvm share_backend_name LVM
    crudini --set /etc/manila/manila.conf lvm \
	share_driver manila.share.drivers.lvm.LVMShareDriver
    crudini --set /etc/manila/manila.conf lvm \
	driver_handles_share_servers False
    crudini --set /etc/manila/manila.conf lvm lvm_share_volume_group manila-volumes
    crudini --set /etc/manila/manila.conf lvm lvm_share_export_ip ${MGMTIP}
    crudini --set /etc/manila/manila.conf lvm 
else
    crudini --set /etc/manila/manila.conf DEFAULT share_backend_name GENERIC
    crudini --set /etc/manila/manila.conf DEFAULT enabled_share_backends generic
    crudini --set /etc/manila/manila.conf DEFAULT enabled_share_protocols NFS,CIFS
    crudini --set /etc/manila/manila.conf DEFAULT \
	scheduler_driver manila.scheduler.drivers.filter.FilterScheduler

    crudini --set /etc/manila/manila.conf generic \
	share_driver manila.share.drivers.generic.GenericShareDriver
    crudini --set /etc/manila/manila.conf generic \
	driver_handles_share_servers True
    if [ "${ML2PLUGIN}" = "openvswitch" ]; then
	crudini --set /etc/manila/manila.conf generic \
	    interface_driver manila.network.linux.interface.OVSInterfaceDriver
    else
	crudini --set /etc/manila/manila.conf generic \
	    interface_driver manila.network.linux.interface.BridgeInterfaceDriver
    fi
    crudini --set /etc/manila/manila.conf generic \
	service_instance_user manila
    crudini --set /etc/manila/manila.conf generic \
	service_instance_password ${MANILA_PASS}

    # Setup key and key configuration
    MANILAHOME=`getent passwd manila | cut -f6 -d:`

    crudini --set /etc/manila/manila.conf generic \
	path_to_private_key ${MANILAHOME}/.ssh/id_rsa
    crudini --set /etc/manila/manila.conf generic \
	path_to_public_key ${MANILAHOME}/.ssh/id_rsa.pub

    mkdir -p ${MANILAHOME}/.ssh
    ssh-keygen -t rsa -f ${MANILAHOME}/.ssh/id_rsa -N ''
    chmod 700 ${MANILAHOME}/.ssh
    chmod 600 ${MANILAHOME}/.ssh/*
    chown -R manila.manila ${MANILAHOME}/.ssh

    # Setup service image and flavor (these are created later in setup-basic-*)
    crudini --set /etc/manila/manila.conf generic \
	service_image_name manila-service-image
    # NB: this flavor id has to match the one created in setup-controller.sh !
    crudini --set /etc/manila/manila.conf generic \
	service_instance_flavor_id 100
    # NB: this CIDR is approximately in the middle of the 10.11-254.0.0
    # range we will allocate to virtual networks.  Recall that osp.py starts
    # allocating flat/vlan nets at 10.11, and the tunnel networks start
    # at 10.254 and go down from there.
    crudini --set /etc/manila/manila.conf generic \
	service_network_cidr 10.133.0.0/16

    crudini --set /etc/manila/manila.conf nova \
	auth_uri http://${CONTROLLER}:5000
    crudini --set /etc/manila/manila.conf nova \
	auth_url http://${CONTROLLER}:35357
    crudini --set /etc/manila/manila.conf nova \
	auth_type password
    crudini --set /etc/manila/manila.conf nova \
	${PROJECT_DOMAIN_PARAM} default
    crudini --set /etc/manila/manila.conf nova \
	${USER_DOMAIN_PARAM} default
    crudini --set /etc/manila/manila.conf nova \
	project_name service
    crudini --set /etc/manila/manila.conf nova \
	username nova
    crudini --set /etc/manila/manila.conf nova \
	password "${NOVA_PASS}"
    crudini --set /etc/manila/manila.conf nova \
	memcached_servers ${CONTROLLER}:11211
    crudini --set /etc/manila/manila.conf nova \
	region_name $REGION

    crudini --set /etc/manila/manila.conf cinder \
	auth_uri http://${CONTROLLER}:5000
    crudini --set /etc/manila/manila.conf cinder \
	auth_url http://${CONTROLLER}:35357
    crudini --set /etc/manila/manila.conf cinder \
	auth_type password
    crudini --set /etc/manila/manila.conf cinder \
	${PROJECT_DOMAIN_PARAM} default
    crudini --set /etc/manila/manila.conf cinder \
	${USER_DOMAIN_PARAM} default
    crudini --set /etc/manila/manila.conf cinder \
	project_name service
    crudini --set /etc/manila/manila.conf cinder \
	username cinder
    crudini --set /etc/manila/manila.conf cinder \
	password "${CINDER_PASS}"
    crudini --set /etc/manila/manila.conf cinder \
	memcached_servers ${CONTROLLER}:11211
    crudini --set /etc/manila/manila.conf cinder \
	region_name $REGION

    crudini --set /etc/manila/manila.conf neutron \
	url http://${CONTROLLER}:9696
    crudini --set /etc/manila/manila.conf neutron \
	auth_uri http://${CONTROLLER}:5000
    crudini --set /etc/manila/manila.conf neutron \
	auth_url http://${CONTROLLER}:35357
    crudini --set /etc/manila/manila.conf neutron \
	auth_type password
    crudini --set /etc/manila/manila.conf neutron \
	${PROJECT_DOMAIN_PARAM} default
    crudini --set /etc/manila/manila.conf neutron \
	${USER_DOMAIN_PARAM} default
    crudini --set /etc/manila/manila.conf neutron \
	project_name service
    crudini --set /etc/manila/manila.conf neutron \
	username neutron
    crudini --set /etc/manila/manila.conf neutron \
	password "${NEUTRON_PASS}"
    crudini --set /etc/manila/manila.conf neutron \
	memcached_servers ${CONTROLLER}:11211
    crudini --set /etc/manila/manila.conf neutron \
	region_name $REGION
fi

if [ $OSVERSION -eq $OSPIKE ]; then
    patch -p1 -d /usr/lib/python2.7/dist-packages \
        < $DIRNAME/etc/manila-pike-bug-1716922.patch
fi

service_restart manila-share
service_enable manila-share

touch $OURDIR/setup-share-host-done

logtstart "share-node"

exit 0
