#!/bin/sh

set -x

DIRNAME=`dirname $0`

# Gotta know the rules!
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Grab our libs
. "$DIRNAME/setup-lib.sh"

if [ "$HOSTNAME" = "$CONTROLLER" -o "$HOSTNAME" = "$NETWORKMANAGER" ]; then
    echo "Cannot run dynamic node setup on controller or networkmanager!"
    exit 0
fi

##
## Ok, we're dynamically adding a compute node to the network.
##

echo "*** Setting up root ssh pubkey access across all nodes..."

# All nodes need to publish public keys, and acquire others'
$DIRNAME/setup-root-ssh.sh 1> $OURDIR/setup-root-ssh.log 2>&1

##
## Now ask the networkmanager to setup our network state.  This will
## blow away our network state that setup-lib.sh calculated locally
## here, and will trash the ssh connection we're about to start if we
## need a mgmt vpn.  So background it and wait for
## $OURDIR/network-manager-added-me to be created; that's our
## signal that it is done.
##
fqdn=`getfqdn $NETWORKMANAGER`
#$SSH $fqdn "$DIRNAME/setup-networkmanager-add-node $HOSTNAME 1>$OURDIR/networkmanager-add-node-$HOSTNAME.log 2>&1 </dev/null" &
$SSH $fqdn "$DIRNAME/setup-networkmanager-add-node.sh $HOSTNAME 1>$OURDIR/setup-networkmanager-add-node-$HOSTNAME.log 2>&1 | tee"

#
# Now that we have complete network info, let's rebuild our per-network
# info.* files.
#
echo "*** Rebuilding per-network metadata files..."
rm -f $OURDIR/info.* $OURDIR/neutron.vars

#while [ ! -f $OURDIR/networkmanager-added-me ]; do
#    sleep 1
#done

# Give the VPN a chance to settle down
PINGED=0
while [ $PINGED -eq 0 ]; do
    sleep 2
    ping -c 1 $CONTROLLER
    if [ $? -eq 0 ]; then
	PINGED=1
    fi
done

echo "*** Setting up OpenVSwitch on $NEWNODE"
$DIRNAME/setup-ovs-node.sh

##
## Now ask the controller to trigger the rest of our setup.
##
#fqdn=`getfqdn $CONTROLLER`
#$SSH $fqdn "$DIRNAME/setup-controller-add-node $HOSTNAME 1>$OURDIR/controller-add-node-$HOSTNAME.log 2>&1 </dev/null"

echo "*** Setting up Nova Compute Service on $NEWNODE"
$DIRNAME/setup-compute.sh

echo "*** Setting up Neutron Network Service on $NEWNODE"
$DIRNAME/setup-compute-network.sh

echo "*** Setting up Ceilometer Telemetry Service on $NEWNODE"
$DIRNAME/setup-compute-telemetry.sh

##
## We're done -- 
##
exit 0
