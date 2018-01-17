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

if [ "$HOSTNAME" != "$CONTROLLER" ]; then
    exit 0;
fi

DOMIGRATE=0
if [ "$1" = '-m' ]; then
    DOMIGRATE=1
    shift
fi

OLDNODES="$@"

if [ -z "$OLDNODES" ] ; then
    echo "ERROR: $0 <list-of-oldnodes-short-names>"
    exit 1
fi

. $SETTINGS
. $OURDIR/admin-openrc.sh

#
# For now, we just do the stupid thing and "evacuate" the VMs from the
# old hypervisor to a new hypervisor.  Let Openstack pick for now...
#
# To do this, we disable the compute service, force it down, and
# evacuate!
#
VALIDNODES=""
for node in $OLDNODES ; do
    echo "*** Forcing compute service on $node down and disabling it ..."
    fqdn=`getfqdn $node`
    if [ -z "$fqdn" ]; then
	echo "ERROR: could not get FQDN for node $node; skipping!"
	continue
    fi
    #id=`nova service-list | awk -v IGNORECASE=1 "/ $fqdn / { print \\$2 }"`
    id=`nova service-list | grep -i $fqdn | awk '// { print $2 }'`
    if [ -z "$id" ]; then
	echo "ERROR: could not get service id for nova-compute on node $node; skipping! ($id)"

	nova service-list

	continue
    fi

    VALIDNODES="$VALIDNODES $node"

    if [ $DOMIGRATE -eq 0 ]; then
	nova service-disable $fqdn nova-compute
        # Hm, this only supported in some versions, so...
	nova service-force-down $fqdn nova-compute
        # REALLY force it down :)
	echo "update services set forced_down=1 where id=$id" \
	    | mysql -u nova --password=${NOVA_DBPASS} nova
	
        # ... do this too, to make sure the service doesn't come up
        # no, don't do it, we can't host-evacuate without it
        #$SSH $fqdn service nova-compute stop
	
	echo "update services set updated_at=NULL where id=$id" \
	    | mysql -u nova --password=${NOVA_DBPASS} nova
    fi
done

#
# Ok, now that all these nodes are down, evacuate them (and this way the
# scheduler won't choose any of the going-down nodes as hosts for the
# evacuated VMs).
#
fqdnlist=""
for node in $VALIDNODES ; do
    echo "*** Evacuating all instances from $node ..."
    fqdn=`getfqdn $node`
    if [ -z "$fqdn" ]; then
	echo "ERROR: could not get FQDN for node $node; skipping!"
	continue
    fi

    if [ $DOMIGRATE -eq 1 ]; then
	servers=`nova hypervisor-servers $fqdn | grep -i $fqdn | awk '// { print $2 }' | xargs`
	for server in $servers ; do
	    nova migrate --poll $server
	    VM_OUTPUT=`nova show $server`
	    VM_STATUS=`echo "$VM_OUTPUT" | grep status | awk '{print $4}'`
	    while [ "$VM_STATUS" != "VERIFY_RESIZE" ]; do
		echo -n "."
		sleep 2
		VM_OUTPUT=`nova show $server`
		VM_STATUS=`echo "$VM_OUTPUT" | grep status | awk '{print $4}'`
	    done
	    nova resize-confirm $server
	    echo "$server instance migrated and resized."
	    echo;
	done
    else
	nova host-evacuate $fqdn
    fi

    # Create a list for the next step so we don't have to keep resolving
    # FQDNs
    fqdnlist="${fqdnlist} $fqdn"
done

#
# Ok, now we want to wait until all those nodes no longer have instances
# on them.
#
success=0
while [ ! $success -eq 1 ]; do
    success=1
    for fqdn in $fqdnlist ; do
	sleep 8
	count=`nova hypervisor-servers $fqdn | awk -v IGNORECASE=1 '/ instance-.* / { print $2 }' | wc -l`
	if [ $count -gt 0 ]; then
	    success=0
	    echo "*** $fqdn still has $count instances"
	fi
    done
done

for node in $VALIDNODES ; do
    echo "*** Deleting compute service on $node ..."
    fqdn=`getfqdn $node`
    if [ -z "$fqdn" ]; then
	echo "ERROR: could not get FQDN for node $node; skipping!"
	continue
    fi
    #id=`nova service-list | awk -v IGNORECASE=1 "/ $fqdn / { print \\$2 }"`
    id=`nova service-list | grep -i $fqdn | awk '// { print $2 }'`
    if [ -z "$id" ]; then
	echo "ERROR: could not get service id for nova-compute on node $node; skipping!"
	continue
    fi
    nova service-delete $id
done

echo "*** Successfully evacuated and deleted nodes $OLDNODES !"
exit 0
