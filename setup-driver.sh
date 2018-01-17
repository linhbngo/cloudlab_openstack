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
# Don't run setup-driver.sh twice
if [ -f $OURDIR/setup-driver-done ]; then
    echo "setup-driver already ran; not running again"
    exit 0
fi
logtstart "driver"

# Copy our source code into $OURDIR for future use:
echo "*** Copying source code into $OURDIR/bin ..."
mkdir -p $OURDIR/bin
rsync -avz $DIRNAME/ $OURDIR/bin/

echo "*** Setting up root ssh pubkey access across all nodes..."

# All nodes need to publish public keys, and acquire others'
$DIRNAME/setup-root-ssh.sh 1> $OURDIR/setup-root-ssh.log 2>&1

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi

if [ "$HOSTNAME" = "$NETWORKMANAGER" ]; then

    echo "*** Waiting for ssh access to all nodes..."

    for node in $NODES ; do
	[ "$node" = "$NETWORKMANAGER" ] && continue

	SUCCESS=1
	fqdn=`getfqdn $node`
	while [ $SUCCESS -ne 0 ] ; do
	    sleep 1
	    ssh -o ConnectTimeout=1 -o PasswordAuthentication=No -o NumberOfPasswordPrompts=0 -o StrictHostKeyChecking=No $fqdn /bin/ls > /dev/null
	    SUCCESS=$?
	done
	echo "*** $node is up!"
    done

    #
    # Get our hosts files setup to point to the new management network.
    # (These were created one-time in setup-lib.sh)
    #
    cat $OURDIR/mgmt-hosts > /etc/hosts.tmp
    # Some services assume they can resolve the hostname prior to network being
    # up (i.e. neutron-ovs-cleanup; see setup-ovs-node.sh).
    echo $MYIP `hostname` >> /etc/hosts.tmp
    cp -p /etc/hosts $OURDIR/hosts.orig
    cat $OURDIR/hosts.orig >> /etc/hosts.tmp
    mv /etc/hosts.tmp /etc/hosts
    for node in $NODES 
    do
	[ "$node" = "$NETWORKMANAGER" ] && continue
	#if unified ; then
	#    continue
	#fi

	fqdn=`getfqdn $node`
	$SSH $fqdn mkdir -p $OURDIR
	#scp -p -o StrictHostKeyChecking=no \
	    #$SETTINGS $OURDIR/mgmt-hosts $OURDIR/mgmt-netmask \
	    #$OURDIR/data-hosts $OURDIR/data-netmask \
	    #$fqdn:$OURDIR
	scp -p -o StrictHostKeyChecking=no \
	    $OURDIR/mgmt-hosts $fqdn:$OURDIR
	# For now, just insert the new hosts in front of the existing ones.
	# setup-{ovs,linuxbridge}-node.sh may do differently.
	$SSH $fqdn "cp -p /etc/hosts $OURDIR/hosts.orig ; cat $OURDIR/mgmt-hosts > /etc/hosts.tmp ; cat $OURDIR/hosts.orig >> /etc/hosts.tmp ; mv /etc/hosts.tmp /etc/hosts"
    done

    echo "*** Setting up the Management Network"

    if [ -z "${MGMTLAN}" ]; then
	echo "*** Building a VPN-based Management Network"

	$DIRNAME/setup-vpn.sh 1> $OURDIR/setup-vpn.log 2>&1

        # Give the VPN a chance to settle down
	PINGED=0
	while [ $PINGED -eq 0 ]; do
	    sleep 2
	    ping -c 1 $CONTROLLER
	    if [ $? -eq 0 ]; then
		PINGED=1
	    fi
	done
    else
	echo "*** Using $MGMTLAN as the Management Network"
    fi

    if [ "${ML2PLUGIN}" = "openvswitch" ]; then
	echo "*** Moving Interfaces into OpenVSwitch Bridges"

	$DIRNAME/setup-ovs.sh 1> $OURDIR/setup-ovs.log 2>&1
    else
	echo "*** Setting up Linux Bridge static network configuration"

	$DIRNAME/setup-linuxbridge.sh 1> $OURDIR/setup-linuxbridge.log 2>&1
    fi

    echo "*** Telling controller to set up OpenStack!"

    ssh -o StrictHostKeyChecking=no ${CONTROLLER} "/bin/touch $OURDIR/networkmanager-driver-done"
fi

# Mark things as done right here, it's safe.
touch $OURDIR/setup-driver-done

if [ "$HOSTNAME" = "$CONTROLLER" ]; then
    #
    # Wait for networkmanager setup to touch a special file indicating that
    # it's finished all the network stuff and we should setup the controller.
    #
    echo "*** Waiting for networkmanager to finish network configuration..."

    while [ ! -f $OURDIR/networkmanager-driver-done ]; do
	sleep 1
    done

    logtend "driver"

    echo "*** Building an Openstack!"

    exec /bin/sh -c "$DIRNAME/setup-controller.sh 1> $OURDIR/setup-controller.log 2>&1 </dev/null"

    exit 1
elif [ "$HOSTNAME" != "$NETWORKMANAGER" ]; then
    logtend "driver"
    exit 0;
fi

logtend "driver"
exit 0
