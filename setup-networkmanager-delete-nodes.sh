#!/bin/sh

##
## This script doesn't really do anything, other than update our metadata
## and copy the new /etc/hosts to the controller.
##

set -x

# Gotta know the rules!
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

DIRNAME=`dirname $0`

#
# NB: make sure to tell setup-lib.sh it needs to update all its info!
#
# This is critical.  Only the networkmanager node has the ability to assign
# IPs or update those metadata files with the complete picture, because it knows
# all the compute nodes that used to exist, and the new ones.
#
export UPDATING=1

# Grab our lib stuff.
. "$DIRNAME/setup-lib.sh"

#
# NB: make sure to stop any future updates; we're good now!
#
export UPDATING=0

if [ "$HOSTNAME" != "$NETWORKMANAGER" ]; then
    exit 0;
fi

OLDNODES="$@"

if [ -z "$OLDNODES" ] ; then
    echo "ERROR: $0 <list-oldnodes-short-names>"
    exit 1
fi

#
# Ok, we copy the new /etc/hosts to the controller and to the new node
# Ugh, also have to copy manifests*.xml, topomap*, fqdn.map
#
echo "*** Copying updated network metadata files to $CONTROLLER ..."

cat $OURDIR/mgmt-hosts > /etc/hosts.tmp
cat $OURDIR/hosts.orig >> /etc/hosts.tmp
mv /etc/hosts.tmp /etc/hosts

fqdn=`getfqdn $CONTROLLER`
$SSH $fqdn mkdir -p $OURDIR
$SCP $SETTINGS \
    $OURDIR/mgmt-hosts $OURDIR/mgmt-netmask $OURDIR/mgmt-o3 $OURDIR/mgmt-o4 \
    $OURDIR/data-hosts.* $OURDIR/data-netmask.* $OURDIR/data-allocation-pool.* \
    $OURDIR/data-network.* $OURDIR/dhcp-agent-ipaddr.* $OURDIR/ipinfo.* \
    $OURDIR/nextsparesubnet $OURDIR/router-ipaddr.* \
    $OURDIR/manifests*.xml $OURDIR/topomap* $OURDIR/fqdn.map \
    $fqdn:$OURDIR
$SSH $fqdn "cat $OURDIR/mgmt-hosts > /etc/hosts.tmp ; cat $OURDIR/hosts.orig >> /etc/hosts.tmp ; mv /etc/hosts.tmp /etc/hosts"

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
    $SSH $fqdn "cat $OURDIR/mgmt-hosts > /etc/hosts.tmp ; cat $OURDIR/hosts.orig >> /etc/hosts.tmp ; mv /etc/hosts.tmp /etc/hosts"
done

exit 0
