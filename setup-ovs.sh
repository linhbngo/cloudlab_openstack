#!/bin/sh

#
# For a neutron setup, we have to move the external interface into
# br-ex, and copy its config to br-ex; move the data lan (ethX) into br-int,
# and copy its config to br-int .  For now, we assume the default route of
# the machine is associated with eth0/br-ex .
#

set -x

# Gotta know the rules!
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

DIRNAME=`dirname $0`

# Grab our libs
. "$DIRNAME/setup-lib.sh"

if [ "$HOSTNAME" != "$NETWORKMANAGER" ]; then
    exit 0;
fi

logtstart "ovs"

maybe_install_packages pssh
PSSH='/usr/bin/parallel-ssh -t 0 -O StrictHostKeyChecking=no '
PHOSTS=""
mkdir -p $OURDIR/pssh.setup-ovs-node.stdout $OURDIR/pssh.setup-ovs-node.stderr

# Do the network manager node first, no ssh
echo "*** Setting up OpenVSwitch on $HOSTNAME"
$DIRNAME/setup-ovs-node.sh

for node in $NODES
do
    [ "$node" = "$NETWORKMANAGER" ] && continue

    fqdn=`getfqdn $node`
    PHOSTS="$PHOSTS -H $fqdn"
done

echo "*** Setting up OpenVSwitch via pssh: $PHOSTS"
$PSSH -o $OURDIR/pssh.setup-ovs-node.stdout -e $OURDIR/pssh.setup-ovs-node.stderr \
    $PHOSTS $DIRNAME/setup-ovs-node.sh

logtend "ovs"

exit 0
