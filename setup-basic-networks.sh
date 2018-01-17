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

logtstart "basic-networks"

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi

. $OURDIR/admin-openrc.sh

#
# Before we do any network stuff, wait for Neutron to be up.  Neutron
# takes awhile to start up, and if that was one of the last things we
# did in setup-controller.sh, it might not be up.  It has to be up for
# any of this stuff to work, so wait forever.  The only reason it would
# fail to come up at this point would be a config error.
#
while [ true ]; do
    echo "Checking for neutron-server to be up..."
    neutron net-list
    if [ $? -eq 0 ]; then
	break
    fi
    sleep 1
done

#
# Before we setup networks, create a Designate zone.
#
if [ $OSVERSION -ge $OSNEWTON ]; then
    mydomain=`hostname | sed -n -e 's/[^\.]*\.\(.*\)$/\1/p'`
    openstack zone create --email root@localhost "${mydomain}."
fi

#
# Setup tunnel-based networks
#
if [ ${DATATUNNELS} -gt 0 ]; then
    i=0
    while [ $i -lt ${DATATUNNELS} ]; do
	LAN="tun${i}"
	#. $OURDIR/info.$LAN
	. $OURDIR/ipinfo.$LAN

	echo "*** Creating GRE data network $LAN and subnet $CIDR ..."

	neutron net-create ${LAN}-net --shared --provider:network_type gre
	neutron subnet-create ${LAN}-net  --name ${LAN}-subnet "$CIDR"
	neutron router-create ${LAN}-router
	neutron router-interface-add ${LAN}-router ${LAN}-subnet
	neutron router-gateway-set ${LAN}-router ext-net

	# Create a share network for this network; and maybe a Designate DNS domain.
	if [ $OSVERSION -ge $OSMITAKA ]; then
	    NETID=`neutron net-show ${LAN}-net | awk '/ id / { print $4 }'`
	    SUBNETID=`neutron subnet-show ${LAN}-subnet | awk '/ id / { print $4 }'`
	    manila share-network-create --name share-${LAN}-net \
		--neutron-net-id $NETID --neutron-subnet-id $SUBNETID
	    if [ $OSVERSION -ge $OSNEWTON ]; then
		neutron net-update $NETID --dns-domain ${mydomain}.
	    fi
	fi

	i=`expr $i + 1`
    done
fi

for lan in ${DATAFLATLANS} ; do
    . $OURDIR/info.${lan}

    name="$lan"
    echo "*** Creating Flat data network ${lan} and subnet ..."

    nmdataip=`cat $OURDIR/data-hosts.${lan} | grep ${NETWORKMANAGER} | sed -n -e 's/^\([0-9]*.[0-9]*.[0-9]*.[0-9]*\).*$/\1/p'`
    allocation_pool=`cat $OURDIR/data-allocation-pool.${lan}`
    cidr=`cat $OURDIR/data-cidr.${lan}`
    # Make sure to set the right gateway IP (to our router)
    routeripaddr=`cat $OURDIR/router-ipaddr.$lan`

    neutron net-create ${name}-net --shared --provider:physical_network ${lan} --provider:network_type flat
    neutron subnet-create ${name}-net --name ${name}-subnet --allocation-pool ${allocation_pool} --gateway $routeripaddr $cidr

    subnetid=`neutron subnet-show ${name}-subnet | awk '/ id / {print $4}'`

    neutron router-create ${name}-router
    neutron router-interface-add ${name}-router ${name}-subnet
    #if [ $PUBLICCOUNT -ge 3 ] ; then
	neutron router-gateway-set ${name}-router ext-net
    #fi

    # Fix up the dhcp agent port IP addr.  We can't set this in the
    # creation command, so do a port update!
    ports=`neutron port-list | grep $subnetid | awk '{print $2}'`
    for port in $ports ; do
	owner=`neutron port-show $port | awk '/ device_owner / {print $4}'`
	#if [ "x$owner" = "xnetwork:router_interface" -a -f $OURDIR/router-ipaddr.$lan ]; then
	#    newipaddr=`cat $OURDIR/router-ipaddr.$lan`
	#    neutron port-update $port --fixed-ip subnet_id=$subnetid,ip_address=$newipaddr
	#fi
	if [ "x$owner" = "xnetwork:dhcp" -a -f $OURDIR/dhcp-agent-ipaddr.$lan ]; then
	    newipaddr=`cat $OURDIR/dhcp-agent-ipaddr.$lan`
	    neutron port-update $port --fixed-ip subnet_id=$subnetid,ip_address=$newipaddr
	fi
    done

    # Create a share network for this network; and maybe a Designate DNS domain.
    if [ $OSVERSION -ge $OSMITAKA ]; then
	NETID=`neutron net-show ${lan}-net | awk '/ id / { print $4 }'`
	SUBNETID=`neutron subnet-show ${lan}-subnet | awk '/ id / { print $4 }'`
	manila share-network-create --name share-${lan}-net \
	    --neutron-net-id $NETID --neutron-subnet-id $SUBNETID
	if [ $OSVERSION -ge $OSNEWTON ]; then
	    neutron net-update $NETID --dns-domain ${mydomain}.
	fi
    fi
done

for lan in ${DATAVLANS} ; do
    . $OURDIR/info.${lan}
    . $OURDIR/ipinfo.${lan}

    echo "*** Creating VLAN data network $lan and subnet $CIDR ..."

    neutron net-create ${lan}-net --shared --provider:physical_network ${DATAVLANDEV} --provider:network_type vlan
    # NB: for now don't specify an allocation_pool:
    #  --allocation-pool ${ALLOCATION_POOL}
    neutron subnet-create ${lan}-net --name ${lan}-subnet "$CIDR"

    neutron router-create ${lan}-router
    neutron router-interface-add ${lan}-router ${lan}-subnet
    #if [ $PUBLICCOUNT -ge 3 ] ; then
	neutron router-gateway-set ${lan}-router ext-net
    #fi

    # Create a share network for this network; and maybe a Designate DNS domain.
    if [ $OSVERSION -ge $OSMITAKA ]; then
	NETID=`neutron net-show ${lan}-net | awk '/ id / { print $4 }'`
	SUBNETID=`neutron subnet-show ${lan}-subnet | awk '/ id / { print $4 }'`
	manila share-network-create --name share-${lan}-net \
	    --neutron-net-id $NETID --neutron-subnet-id $SUBNETID
	if [ $OSVERSION -ge $OSNEWTON ]; then
	    neutron net-update $NETID --dns-domain ${mydomain}.
	fi
    fi
done

#
# Setup VXLAN-based networks
#
if [ ${DATAVXLANS} -gt 0 ]; then
    i=0
    while [ $i -lt ${DATAVXLANS} ]; do
	LAN="vxlan${i}"
	#. $OURDIR/info.$LAN
	. $OURDIR/ipinfo.$LAN

	echo "*** Creating VXLAN data network $LAN and subnet $CIDR ..."

	neutron net-create ${LAN}-net --shared --provider:network_type vxlan
	neutron subnet-create ${LAN}-net  --name ${LAN}-subnet "$CIDR"
	neutron router-create ${LAN}-router
	neutron router-interface-add ${LAN}-router ${LAN}-subnet
	neutron router-gateway-set ${LAN}-router ext-net

	# Create a share network for this network; and maybe a Designate DNS domain.
	if [ $OSVERSION -ge $OSMITAKA ]; then
	    NETID=`neutron net-show ${LAN}-net | awk '/ id / { print $4 }'`
	    SUBNETID=`neutron subnet-show ${LAN}-subnet | awk '/ id / { print $4 }'`
	    manila share-network-create --name share-${LAN}-net \
		--neutron-net-id $NETID --neutron-subnet-id $SUBNETID
	    if [ $OSVERSION -ge $OSNEWTON ]; then
		neutron net-update $NETID --dns-domain ${mydomain}.
	    fi
	fi

	i=`expr $i + 1`
    done
fi

#
# Finally, now that we've created all our routers (and their gateways to
# the ext-net), create floating IPs until we get an error.
#
#while [ true ]; do
#    neutron floatingip-create ext-net
#    if [ ! $? -eq 0 ]; then
#	break
#    fi
#done

logtend "basic-networks"

exit 0
