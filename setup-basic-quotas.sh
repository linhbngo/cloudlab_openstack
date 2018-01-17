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

logtstart "basic-quotas"

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi

. $OURDIR/admin-openrc.sh

if [ ${DEFAULT_SECGROUP_ENABLE_SSH_ICMP} -eq 1 ]; then
    echo "*** Setting up security group default rules..."
    if [ $OSVERSION -le $OSMITAKA ]; then
	nova secgroup-add-rule default icmp -1 -1 0.0.0.0/0
	nova secgroup-add-rule default tcp 22 22 0.0.0.0/0
    else
	ADMIN_PROJECT_ID=`openstack project list | awk '/ admin / {print $2}'`
	ADMIN_SEC_GROUP=`openstack security group list --project ${ADMIN_PROJECT_ID} | awk '/ default / {print $2}'`
        openstack security group rule create \
	    --protocol tcp --dst-port 22:22 ${ADMIN_SEC_GROUP}
	openstack security group rule create \
	    --protocol icmp ${ADMIN_SEC_GROUP}
    fi
fi

if [ $QUOTASOFF -eq 1 ]; then
    nova quota-class-update --instances -1 default
    nova quota-class-update --cores -1 default
    nova quota-class-update --ram -1 default
    nova quota-class-update --metadata-items -1 default
    nova quota-class-update --injected-files -1 default
    nova quota-class-update --injected-file-content-bytes -1 default
    nova quota-class-update --injected-file-path-bytes -1 default
    nova quota-class-update --key-pairs -1 default
    nova quota-class-update --server-groups -1 default
    nova quota-class-update --server-group-members -1 default
    if [ $OSVERSION -le $OSMITAKA ]; then
	nova quota-class-update --floating-ips -1 default
	nova quota-class-update --fixed-ips -1 default
	nova quota-class-update --security-groups -1 default
	nova quota-class-update --security-group-rules -1 default
    fi

    neutron quota-update --network -1
    neutron quota-update --subnet -1
    neutron quota-update --port -1
    neutron quota-update --router -1
    neutron quota-update --floatingip -1
    neutron quota-update --security-group -1
    neutron quota-update --security-group-rule -1
    neutron quota-update --rbac-policy -1
    neutron quota-update --vip -1
    neutron quota-update --pool -1
    neutron quota-update --member -1
    neutron quota-update --health-monitor -1

    cinder quota-class-update --volumes -1 default
    cinder quota-class-update --snapshots -1 default
    cinder quota-class-update --gigabytes -1 default
    # Guess you can't set these via CLI?
    #cinder quota-class-update --backup-_gigabytes -1 default
    #cinder quota-class-update --backups -1 default
    #cinder quota-class-update --per-volume-gigabytes -1 default

    openstack quota set --class --ram -1 admin
    openstack quota set --class --secgroup-rules -1 admin
    openstack quota set --class --instances -1 admin
    openstack quota set --class --key-pairs -1 admin
    openstack quota set --class --fixed-ips -1 admin
    openstack quota set --class --secgroups -1 admin
    openstack quota set --class --injected-file-size -1 admin
    openstack quota set --class --floating-ips -1 admin
    openstack quota set --class --injected-files -1 admin
    openstack quota set --class --cores -1 admin
    openstack quota set --class --injected-path-size -1 admin
    openstack quota set --class --gigabytes -1 admin
    openstack quota set --class --volumes -1 admin
    openstack quota set --class --snapshots -1 admin
    openstack quota set --class --volume-type -1 admin
fi

logtend "basic-quotas"
