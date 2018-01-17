#!/bin/sh

##
## Setup a root ssh key on the calling node, and broadcast it to all the
## other nodes' authorized_keys file.
##

set -x

# Gotta know the rules!
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Grab our libs
. "`dirname $0`/setup-lib.sh"

logtstart "root-ssh"

KEYNAME=id_rsa

# Remove it if it exists...
rm -f /root/.ssh/${KEYNAME} /root/.ssh/${KEYNAME}.pub

##
## Figure out our strategy.  Are we using the new geni_certificate and
## geni_key support to generate the same keypair on each host, or not.
##
geni-get key > $OURDIR/$KEYNAME
chmod 600 $OURDIR/${KEYNAME}
if [ -s $OURDIR/${KEYNAME} ] ; then
    ssh-keygen -f $OURDIR/${KEYNAME} -y > $OURDIR/${KEYNAME}.pub
    chmod 600 $OURDIR/${KEYNAME}.pub
    mkdir -p /root/.ssh
    chmod 600 /root/.ssh
    cp -p $OURDIR/${KEYNAME} $OURDIR/${KEYNAME}.pub /root/.ssh/
    ps axwww > $OURDIR/ps.txt
    cat $OURDIR/${KEYNAME}.pub >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    logtend "root-ssh"
    exit 0
fi

##
## If geni calls are not available, make ourself a keypair; this gets copied
## to other roots' authorized_keys.
##
if [ ! -f /root/.ssh/${KEYNAME} ]; then
    ssh-keygen -t rsa -f /root/.ssh/${KEYNAME} -N ''
fi

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi

if [ $GENIUSER -eq 1 ]; then
    SHAREDIR=/proj/$EPID/exp/$EEID/tmp

    cp /root/.ssh/${KEYNAME}.pub $SHAREDIR/$HOSTNAME

    for node in $NODES ; do
	while [ ! -f $SHAREDIR/$node ]; do
            sleep 1
	done
	echo $node is up
	cat $SHAREDIR/$node >> /root/.ssh/authorized_keys
    done
else
    for node in $NODES ; do
	if [ "$node" != "$HOSTNAME" ]; then 
	    fqdn=`getfqdn $node`
	    SUCCESS=1
	    while [ $SUCCESS -ne 0 ]; do
		su -c "$SSH  -l $SWAPPER $fqdn sudo tee -a /root/.ssh/authorized_keys" $SWAPPER < /root/.ssh/${KEYNAME}.pub
		SUCCESS=$?
		sleep 1
	    done
	fi
    done
fi

logtend "root-ssh"

exit 0
