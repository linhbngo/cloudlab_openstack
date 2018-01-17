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

if [ "$HOSTNAME" = "$CONTROLLER" -o "$HOSTNAME" = "$NETWORKMANAGER" ]; then
    exit 0;
fi

if [ -f $OURDIR/setup-compute-network-done ]; then
    exit 0
fi

logtstart "compute-network"

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi

$DIRNAME/setup-network-plugin.sh

crudini --set /etc/nova/nova.conf DEFAULT \
    network_api_class nova.network.neutronv2.api.API
crudini --set /etc/nova/nova.conf DEFAULT \
    security_group_api neutron
if [ "${ML2PLUGIN}" = "openvswitch" ]; then
    crudini --set /etc/nova/nova.conf DEFAULT linuxnet_interface_driver \
	nova.network.linux_net.LinuxOVSInterfaceDriver
else
    crudini --set /etc/nova/nova.conf DEFAULT linuxnet_interface_driver \
	nova.network.linux_net.NeutronLinuxBridgeInterfaceDriver
fi
crudini --set /etc/nova/nova.conf DEFAULT \
    firewall_driver nova.virt.firewall.NoopFirewallDriver

crudini --set /etc/nova/nova.conf neutron \
    url http://$CONTROLLER:9696
crudini --set /etc/nova/nova.conf neutron \
    auth_strategy keystone
if [ $OSVERSION -le $OSKILO ]; then
    crudini --set /etc/nova/nova.conf neutron \
	admin_auth_url http://$CONTROLLER:35357/v2.0
    crudini --set /etc/nova/nova.conf neutron \
	admin_tenant_name service
    crudini --set /etc/nova/nova.conf neutron \
	admin_username neutron
    crudini --set /etc/nova/nova.conf neutron \
	admin_password ${NEUTRON_PASS}
else
    crudini --set /etc/nova/nova.conf neutron \
	auth_url http://$CONTROLLER:35357
    crudini --set /etc/nova/nova.conf neutron ${AUTH_TYPE_PARAM} password
    crudini --set /etc/nova/nova.conf neutron ${PROJECT_DOMAIN_PARAM} default
    crudini --set /etc/nova/nova.conf neutron ${USER_DOMAIN_PARAM} default
    crudini --set /etc/nova/nova.conf neutron region_name $REGION
    crudini --set /etc/nova/nova.conf neutron project_name service
    crudini --set /etc/nova/nova.conf neutron username neutron
    crudini --set /etc/nova/nova.conf neutron password ${NEUTRON_PASS}
fi
if [ $OSVERSION -ge $OSMITAKA -o $KEYSTONEUSEMEMCACHE -eq 1 ]; then
    crudini --set /etc/nova/nova.conf neutron \
	memcached_servers ${CONTROLLER}:11211
fi

touch $OURDIR/setup-compute-network-done

logtend "compute-network"

exit 0
