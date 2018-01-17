#!/bin/sh

##
## Setup a OpenStack node to run the openvswitch ML2 plugin.
##

set -x

# Gotta know the rules!
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Grab our libs
. "`dirname $0`/setup-lib.sh"

if [ -f $OURDIR/setup-network-plugin-openvswitch-done ]; then
    exit 0
fi

logtstart "network-plugin-openvswitch"

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

maybe_install_packages neutron-plugin-ml2 neutron-plugin-openvswitch-agent \
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
    mechanism_drivers openvswitch
extdrivers=
if [ $OSVERSION -ge $OSNEWTON ]; then
    extdrivers="dns"
fi
if [ -n "$extdrivers" ]; then
    crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 \
        extension_drivers $extdrivers
fi
crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_flat \
    flat_networks ${flat_networks}
crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_gre \
    tunnel_id_ranges 1:1000
cat <<EOF >>/etc/neutron/plugins/ml2/ml2_conf.ini
[ml2_type_vlan]
${network_vlan_ranges}
EOF
crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_vxlan \
    vni_ranges 3000:4000
#crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_vxlan \
#    vxlan_group 224.0.0.1
crudini --set /etc/neutron/plugins/ml2/openvswitch_agent.ini securitygroup \
    enable_security_group True
crudini --set /etc/neutron/plugins/ml2/openvswitch_agent.ini securitygroup \
    enable_ipset True
if [ -n "$fwdriver" ]; then
    crudini --set /etc/neutron/plugins/ml2/openvswitch_agent.ini securitygroup \
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
cat <<EOF >> /etc/neutron/plugins/ml2/ml2_conf.ini
[ovs]
${gre_local_ip}
${enable_tunneling}
${bridge_mappings}

[agent]
${tunnel_types}
EOF

if [ $OSVERSION -ge $OSMITAKA ]; then
    # In Mitaka, these seem to need to be specifically in the agent file.
    # Must be a change in neutron-server init script.
    # Just slap these in.
    cat <<EOF >> /etc/neutron/plugins/ml2/openvswitch_agent.ini
[ovs]
${gre_local_ip}
${enable_tunneling}
${bridge_mappings}

[agent]
${tunnel_types}
EOF
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
# Patch the neutron openvswitch agent to try to stop inadvertent spoofing on
# the public emulab/cloudlab control net, sigh.
#
if [ $OSVERSION -le $OSLIBERTY ]; then
    patch -d / -p0 < $DIRNAME/etc/neutron-${OSCODENAME}-openvswitch-remove-all-flows-except-system-flows.patch
else
    patch -d / -p0 < $DIRNAME/etc/neutron-${OSCODENAME}-ovs-reserved-cookies.patch
fi

#
# https://git.openstack.org/cgit/openstack/neutron/commit/?id=51f6b2e1c9c2f5f5106b9ae8316e57750f09d7c9
#
if [ $OSVERSION -ge $OSLIBERTY -a $OSVERSION -lt $OSNEWTON ]; then
    patch -d / -p0 < $DIRNAME/etc/neutron-liberty-ovs-agent-segmentation-id-None.patch
fi

#
# Neutron depends on bridge module, but it doesn't autoload it.
#
modprobe bridge
echo bridge >> /etc/modules

service_restart openvswitch-switch
service_enable openvswitch-switch
service_restart nova-compute
# Restart the ovs-cleanup service to ensure it is using the patched code
# and thus will not delete our new cookie-based flows once we add them.
service_restart neutron-ovs-cleanup
service_enable neutron-ovs-cleanup
if [ $OSVERSION -lt $OSMITAKA ]; then
    service_restart neutron-plugin-openvswitch-agent
    service_enable neutron-plugin-openvswitch-agent
else
    service_restart neutron-openvswitch-agent
    service_enable neutron-openvswitch-agent
fi

if [ $OSVERSION -gt $OSLIBERTY ]; then
    # If we are using the reserved cookies patch, we have to figure out
    # what our cookie is, read it, and then edit all the anti-spoofing
    # flows to have our reserved cookie -- and then re-insert them all.
    # We don't know what our per-host reserved cookie is until the
    # patched ovs code creates one on the first startup after patch.
    echo "*** Re-adding OVS anti-spoofing flows with reserved cookie..."
    i=30
    while [ ! -f /var/lib/neutron/ovs-default-flows.reserved_cookie -a $i -gt 0 ]; do
	sleep 1
	i=`expr $i - 1`
    done
    # Sleep to let the agent settle further.
    sleep 5
    # Restart the ovs agent one more time; something in its first-time
    # startup doesn't catch the reserved/preserved cookies, and ends up
    # wiping our flows.
    service_restart neutron-openvswitch-agent
    # Let the agent settle again...
    sleep 5
    if [ -f /var/lib/neutron/ovs-default-flows.reserved_cookie -a -f /etc/neutron/ovs-default-flows/br-ex ]; then
	cookie=`cat /var/lib/neutron/ovs-default-flows.reserved_cookie`
	for fl in `cat /etc/neutron/ovs-default-flows/br-ex`; do
	    echo "cookie=$cookie,$fl" >> /etc/neutron/ovs-default-flows/br-ex.tmp
	    ovs-ofctl add-flow br-ex "cookie=$cookie,$fl"
	done
	mv /etc/neutron/ovs-default-flows/br-ex.tmp /etc/neutron/ovs-default-flows/br-ex
    fi
fi

touch $OURDIR/setup-network-plugin-openvswitch-done

logtend "network-plugin-openvswitch"

exit 0
