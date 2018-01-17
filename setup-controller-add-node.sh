#!/bin/sh

set -x

# Gotta know the rules!
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

DIRNAME=`dirname $0`

# Grab our lib stuff.
. "$DIRNAME/setup-lib.sh"

if [ "$HOSTNAME" != "$NETWORKMANAGER" ]; then
    exit 0;
fi

NEWNODE="$1"

if [ -z "$NEWNODE" ] ; then
    echo "ERROR: $0 <newnode-short-name>"
    exit 1
fi

#
# Ok, we copy the new /etc/hosts to the controller and to the new node
# Ugh, also have to copy manifests*.xml, topomap*, fqdn.map
#
echo "*** Copying updated network metadata files to $CONTROLLER and $NEWNODE ..."

fqdn=`getfqdn $NEWNODE`
$SSH $fqdn mkdir -p $OURDIR
$SCP $SETTINGS $OURDIR/admin-openrc.* \
    $OURDIR/mgmt-hosts $OURDIR/mgmt-netmask $OURDIR/mgmt-o3 $OURDIR/mgmt-o4 \
    $OURDIR/data-hosts.* $OURDIR/data-netmask.* $OURDIR/data-allocation-pool.* \
    $OURDIR/data-network.* $OURDIR/dhcp-agent-ipaddr.* $OURDIR/ipinfo.* \
    $OURDIR/nextsparesubnet $OURDIR/router-ipaddr.* \
    $OURDIR/manifests*.xml $OURDIR/topomap* $OURDIR/fqdn.map \
    $fqdn:$OURDIR
$SSH $fqdn cp $OURDIR/mgmt-hosts /etc/hosts
$SSH $fqdn 'echo 127.0.0.1 localhost | tee -a /etc/hosts'

#
# Update the management network if necessary
#
echo "*** Updating up the Management Network"

if [ -z "${MGMTLAN}" ]; then
    echo "*** Updating the VPN-based Management Network"

    $DIRNAME/setup-vpn.sh 1> $OURDIR/setup-vpn.log 2>&1

    # Give the VPN a chance to settle down
    PINGED=0
    while [ $PINGED -eq 0 ]; do
	sleep 2
	ping -c 1 $NEWNODE
	if [ $? -eq 0 ]; then
	    PINGED=1
	fi
    done
else
    echo "*** Using $MGMTLAN as the Management Network"
fi

#
# Now copy the updated $OURDIR/mgmt-hosts to all the other nodes and
# update /etc/hosts .
#
for node in $NODES
do
    [ "$node" = "$NETWORKMANAGER" ] && continue
    [ "$node" = "$NEWNODE" ] && continue

    fqdn=`getfqdn $node`
    scp -p -o StrictHostKeyChecking=no $OURDIR/mgmt-hosts $fqdn:$OURDIR
    $SSH $fqdn cp -p $OURDIR/mgmt-hosts /etc/hosts
    $SSH $fqdn 'echo 127.0.0.1 localhost | tee -a /etc/hosts'
done

##
## Done!
##
#echo "Telling new node $NEWNODE that we have set it up completely..."
#fqdn=`getfqdn $NEWNODE`
#scp -p -o StrictHostKeyChecking=no $OURDIR/mgmt-hosts $fqdn:$OURDIR
#$SSH $fqdn cp -p $OURDIR/mgmt-hosts /etc/hosts
#$SSH $fqdn 'echo 127.0.0.1 localhost | tee -a /etc/hosts'

# Remove our lockfile
rm -f $OURDIR/updating-nodes

exit 0
