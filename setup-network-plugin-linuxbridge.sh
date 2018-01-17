#!/bin/sh

##
## Setup a OpenStack node to run the linuxbridge ML2 plugin.
##

set -x

# Gotta know the rules!
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Grab our libs
. "`dirname $0`/setup-lib.sh"

if [ -f $OURDIR/setup-network-plugin-linuxbridge-done ]; then
    exit 0
fi

logtstart "network-plugin-linuxbridge"

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi
if [ -f $LOCALSETTINGS ]; then
    . $LOCALSETTINGS
fi

# Grab the neutron configuration we computed in setup-lib.sh
. $OURDIR/neutron.vars

cat <<EOF >> /etc/sysctl.conf
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
EOF

sysctl -p

maybe_install_packages neutron-plugin-ml2 neutron-plugin-linuxbridge-agent \
    conntrack

# Only the controller node runs neutron-server and needs the DB.
if [ "$HOSTNAME" != "$CONTROLLER" ]; then
    crudini --del /etc/neutron/neutron.conf database connection
fi
crudini --del /etc/neutron/neutron.conf keystone_authtoken auth_host
crudini --del /etc/neutron/neutron.conf keystone_authtoken auth_port
crudini --del /etc/neutron/neutron.conf keystone_authtoken auth_protocol

crudini --set /etc/neutron/neutron.conf DEFAULT auth_strategy keystone
crudini --set /etc/neutron/neutron.conf DEFAULT verbose ${VERBOSE_LOGGING}
crudini --set /etc/neutron/neutron.conf DEFAULT debug ${DEBUG_LOGGING}
crudini --set /etc/neutron/neutron.conf DEFAULT core_plugin ml2
crudini --set /etc/neutron/neutron.conf DEFAULT service_plugins 'router,metering'
crudini --set /etc/neutron/neutron.conf DEFAULT allow_overlapping_ips True
crudini --set /etc/neutron/neutron.conf DEFAULT notification_driver messagingv2

if [ $OSVERSION -lt $OSKILO ]; then
    crudini --set /etc/neutron/neutron.conf DEFAULT rpc_backend rabbit
    crudini --set /etc/neutron/neutron.conf DEFAULT rabbit_host $CONTROLLER
    crudini --set /etc/neutron/neutron.conf DEFAULT rabbit_userid ${RABBIT_USER}
    crudini --set /etc/neutron/neutron.conf DEFAULT rabbit_password "${RABBIT_PASS}"
elif [ $OSVERSION -lt $OSNEWTON ]; then
    crudini --set /etc/neutron/neutron.conf DEFAULT rpc_backend rabbit
    crudini --set /etc/neutron/neutron.conf oslo_messaging_rabbit \
	rabbit_host $CONTROLLER
    crudini --set /etc/neutron/neutron.conf oslo_messaging_rabbit \
	rabbit_userid ${RABBIT_USER}
    crudini --set /etc/neutron/neutron.conf oslo_messaging_rabbit \
	rabbit_password "${RABBIT_PASS}"
else
    crudini --set /etc/neutron/neutron.conf DEFAULT transport_url $RABBIT_URL
fi

if [ $OSVERSION -lt $OSKILO ]; then
    crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	auth_uri http://${CONTROLLER}:5000/${KAPISTR}
    crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	identity_uri http://${CONTROLLER}:35357
    crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	admin_tenant_name service
    crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	admin_user neutron
    crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	admin_password "${NEUTRON_PASS}"
else
    crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	auth_uri http://${CONTROLLER}:5000
    crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	auth_url http://${CONTROLLER}:35357
    crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	${AUTH_TYPE_PARAM} password
    crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	${PROJECT_DOMAIN_PARAM} default
    crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	${USER_DOMAIN_PARAM} default
    crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	project_name service
    crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	username neutron
    crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	password "${NEUTRON_PASS}"
fi
if [ $OSVERSION -ge $OSMITAKA -o $KEYSTONEUSEMEMCACHE -eq 1 ]; then
    crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	memcached_servers ${CONTROLLER}:11211
fi

crudini --set /etc/neutron/neutron.conf DEFAULT \
    notify_nova_on_port_status_changes True
crudini --set /etc/neutron/neutron.conf DEFAULT \
    notify_nova_on_port_data_changes True
crudini --set /etc/neutron/neutron.conf DEFAULT \
    nova_url http://${CONTROLLER}:8774/v2
if [ $OSVERSION -lt $OSKILO ]; then
    crudini --set /etc/neutron/neutron.conf nova \
	auth_uri http://${CONTROLLER}:5000/${KAPISTR}
    crudini --set /etc/neutron/neutron.conf nova \
	identity_uri http://${CONTROLLER}:35357
    crudini --set /etc/neutron/neutron.conf nova \
	admin_tenant_name service
    crudini --set /etc/neutron/neutron.conf nova \
	admin_user nova
    crudini --set /etc/neutron/neutron.conf nova \
	admin_password "${NOVA_PASS}"
else
    crudini --set /etc/neutron/neutron.conf nova \
	auth_uri http://${CONTROLLER}:5000
    crudini --set /etc/neutron/neutron.conf nova \
	auth_url http://${CONTROLLER}:35357
    crudini --set /etc/neutron/neutron.conf nova \
	${AUTH_TYPE_PARAM} password
    crudini --set /etc/neutron/neutron.conf nova \
	${PROJECT_DOMAIN_PARAM} default
    crudini --set /etc/neutron/neutron.conf nova \
	${USER_DOMAIN_PARAM} default
    crudini --set /etc/neutron/neutron.conf nova \
	project_name service
    crudini --set /etc/neutron/neutron.conf nova \
	username nova
    crudini --set /etc/neutron/neutron.conf nova \
	password "${NOVA_PASS}"
fi
if [ $OSVERSION -ge $OSMITAKA -o $KEYSTONEUSEMEMCACHE -eq 1 ]; then
    crudini --set /etc/neutron/neutron.conf nova \
	memcached_servers ${CONTROLLER}:11211
fi
if [ $OSVERSION -ge $OSOCATA ]; then
    crudini --set /etc/neutron/neutron.conf placement \
	os_region_name $REGION
    crudini --set /etc/neutron/neutron.conf placement \
	auth_url http://${CONTROLLER}:35357/v3
    crudini --set /etc/neutron/neutron.conf placement \
	${AUTH_TYPE_PARAM} password
    crudini --set /etc/neutron/neutron.conf placement \
	${PROJECT_DOMAIN_PARAM} default
    crudini --set /etc/neutron/neutron.conf placement \
	${USER_DOMAIN_PARAM} default
    crudini --set /etc/neutron/neutron.conf placement \
	project_name service
    crudini --set /etc/neutron/neutron.conf placement \
	username placement
    crudini --set /etc/neutron/neutron.conf placement \
	password "${PLACEMENT_PASS}"
fi

crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 \
    type_drivers ${network_types}
crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 \
    tenant_network_types ${network_types}
crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 \
    mechanism_drivers 'linuxbridge,l2population'
extdrivers=port_security
if [ $OSVERSION -ge $OSNEWTON ]; then
    extdrivers="${extdrivers},dns"
fi
crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 \
    extension_drivers $extdrivers
crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_flat \
    flat_networks ${flat_networks}
#crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_gre \
#    tunnel_id_ranges 1:1000
cat <<EOF >>/etc/neutron/plugins/ml2/ml2_conf.ini
[ml2_type_vlan]
${network_vlan_ranges}
EOF
crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_vxlan \
    vni_ranges 3000:4000
#crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_vxlan \
#    vxlan_group 224.0.0.1

cat <<EOF >> /etc/neutron/plugins/ml2/linuxbridge_agent.ini
[linux_bridge]
${bridge_mappings}
${extra_mappings}

[vxlan]
enable_vxlan = True
${gre_local_ip}
l2_population = True

[agent]
prevent_arp_spoofing = True
EOF
crudini --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini securitygroup \
    enable_security_group True
crudini --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini securitygroup \
    enable_ipset True
if [ -n "$fwdriver" ]; then
    crudini --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini securitygroup \
	firewall_driver $fwdriver
fi
crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini securitygroup \
    enable_security_group True
crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini securitygroup \
    enable_ipset True
if [ -n "$fwdriver" ]; then
    crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini securitygroup \
	firewall_driver $fwdriver
fi


#
# Ok, also put our FQDN into the hosts file so that local applications can
# resolve that pair even if the network happens to be down.  This happens,
# for instance, because of our anti-ARP spoofing "patch" to the openvswitch
# agent (the agent remove_all_flow()s on a switch periodically and inserts a
# default normal forwarding rule, plus anything it needs --- our patch adds some
# anti-ARP spoofing rules after remove_all but BEFORE the default normal rule
# gets added back (this is just the nature of the existing code in Juno and Kilo
# (the situation is easier to patch more nicely on the master branch, but we
# don't have Liberty yet)) --- and because it adds the rules via command line
# using sudo, and sudo tries to lookup the hostname --- this can cause a hang.)
# Argh, what a pain.  For the rest of this hack, see setup-ovs-node.sh, and
# setup-networkmanager.sh and setup-compute-network.sh where we patch the 
# neutron openvswitch agent.
#
echo "$MYIP    $NFQDN $PFQDN" >> /etc/hosts

#
# Neutron depends on bridge module, but it doesn't autoload it.
#
modprobe bridge
echo bridge >> /etc/modules

service_restart nova-compute
if [ $OSVERSION -lt $OSMITAKA ]; then
    service_restart neutron-plugin-linuxbridge-agent
    service_enable neutron-plugin-linuxbridge-agent
else
    service_restart neutron-linuxbridge-agent
    service_enable neutron-linuxbridge-agent
fi

touch $OURDIR/setup-network-plugin-linuxbridge-done

logtend "network-plugin-linuxbridge"

exit 0
