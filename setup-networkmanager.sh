#!/bin/sh

##
## Setup the OpenStack networkmanager node for Neutron.
##

set -x

# Gotta know the rules!
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Grab our libs
. "`dirname $0`/setup-lib.sh"

if [ "$HOSTNAME" != "$NETWORKMANAGER" ]; then
    exit 0;
fi

if [ -f $OURDIR/setup-networkmanager-done ]; then
    exit 0
fi

logtstart "networkmanager"

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi

#
# Configure our Neutron ML2 plugin.
#
$DIRNAME/setup-network-plugin.sh

# Grab the neutron configuration we computed in setup-lib.sh
. $OURDIR/neutron.vars

#
# This is a nasty bug in oslo_service; see 
# https://review.openstack.org/#/c/256267/
#
if [ $OSVERSION -ge $OSKILO ]; then
    maybe_install_packages python-oslo.service
    patch -d / -p0 < $DIRNAME/etc/oslo_service-liberty-sig-MAINLOOP.patch
fi

cat <<EOF >> /etc/sysctl.conf
net.ipv4.ip_forward=1
EOF

sysctl -p

maybe_install_packages neutron-l3-agent neutron-dhcp-agent neutron-metering-agent

# Configure the L3 agent.
crudini --set /etc/neutron/l3_agent.ini DEFAULT \
    interface_driver $interface_driver
crudini --set /etc/neutron/l3_agent.ini DEFAULT use_namespaces True
if [ "${ML2PLUGIN}" = "openvswitch" ]; then
    crudini --set /etc/neutron/l3_agent.ini DEFAULT external_network_bridge br-ex
else
    crudini --set /etc/neutron/l3_agent.ini DEFAULT external_network_bridge ''
fi
#crudini --set /etc/neutron/l3_agent.ini DEFAULT router_delete_namespaces True
crudini --set /etc/neutron/l3_agent.ini DEFAULT verbose ${VERBOSE_LOGGING}
crudini --set /etc/neutron/l3_agent.ini DEFAULT debug ${DEBUG_LOGGING}

# Configure the DHCP agent.
crudini --set /etc/neutron/dhcp_agent.ini DEFAULT \
    interface_driver $interface_driver
crudini --set /etc/neutron/dhcp_agent.ini DEFAULT \
    dhcp_driver neutron.agent.linux.dhcp.Dnsmasq
if [ "${ML2PLUGIN}" = "openvswitch" ]; then
    crudini --set /etc/neutron/dhcp_agent.ini DEFAULT use_namespaces True
    #crudini --set /etc/neutron/dhcp_agent.ini DEFAULT dhcp_delete_namespaces True
else
    crudini --set /etc/neutron/dhcp_agent.ini DEFAULT enable_isolated_metadata True
fi
crudini --set /etc/neutron/dhcp_agent.ini DEFAULT verbose ${VERBOSE_LOGGING}
crudini --set /etc/neutron/dhcp_agent.ini DEFAULT debug ${DEBUG_LOGGING}

#
# NB: theoretically, Mitaka and onwards automatically handles MTU, but
# suppose I mix GRE and VXLAN networks locally... I will fragment.  So
# let's just be consistent and use 1450.  This was previously broken for
# VXLANs on large packets because we were using the GRE-style MTU of 1454.
#

# Uncomment if dhcp has trouble due to MTU
crudini --set /etc/neutron/dhcp_agent.ini DEFAULT \
    dnsmasq_config_file /etc/neutron/dnsmasq-neutron.conf
cat <<EOF >>/etc/neutron/dnsmasq-neutron.conf
dhcp-option-force=26,1450
log-queries
log-dhcp
no-resolv
server=8.8.8.8
EOF
pkill dnsmasq

# Setup the Metadata agent.
if [ $OSVERSION -lt $OSKILO ]; then
    crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
	auth_url http://$CONTROLLER:5000/v2.0
    crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
	auth_region $REGION
    crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
	admin_tenant_name service
    crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
	admin_user neutron
    crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
	admin_password ${NEUTRON_PASS}
else
    crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
	auth_uri http://${CONTROLLER}:5000
    crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
	auth_url http://${CONTROLLER}:35357/v2.0
    crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
	auth_region $REGION
    crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
	${AUTH_TYPE_PARAM} password
    crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
	${PROJECT_DOMAIN_PARAM} default
    crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
	${USER_DOMAIN_PARAM} default
    crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
	project_name service
    crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
	username neutron
    crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
	password "${NEUTRON_PASS}"
    crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
	admin_tenant_name service
    crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
	admin_user neutron
    crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
	admin_password "${NEUTRON_PASS}"
fi
crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
    nova_metadata_ip ${CONTROLLER}
crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
    metadata_proxy_shared_secret ${NEUTRON_METADATA_SECRET}
crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
    verbose ${VERBOSE_LOGGING}
crudini --set /etc/neutron/metadata_agent.ini DEFAULT \
    debug ${DEBUG_LOGGING}

# Setup the metering agent.
crudini --set /etc/neutron/metering_agent.ini DEFAULT debug True
crudini --set /etc/neutron/metering_agent.ini DEFAULT \
    driver neutron.services.metering.drivers.iptables.iptables_driver.IptablesMeteringDriver
crudini --set /etc/neutron/metering_agent.ini DEFAULT measure_interval 30
crudini --set /etc/neutron/metering_agent.ini DEFAULT report_interval 300
crudini --set /etc/neutron/metering_agent.ini DEFAULT \
    interface_driver $interface_driver
crudini --set /etc/neutron/metering_agent.ini DEFAULT \
    use_namespaces True

service_restart neutron-l3-agent
service_enable neutron-l3-agent
service_restart neutron-dhcp-agent
service_enable neutron-dhcp-agent
service_restart neutron-metadata-agent
service_enable neutron-metadata-agent
service_restart neutron-metering-agent
service_enable neutron-metering-agent

touch $OURDIR/setup-networkmanager-done

logtend "networkmanager"

exit 0
