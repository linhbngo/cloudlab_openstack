#!/bin/sh

##
## Setup an OpenVPN client for the management network.  Just saves
## a couple SSH connections from the server driving the setup.
##

set -x

# Gotta know the rules!
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Grab our libs
. "`dirname $0`/setup-lib.sh"

logtstart "vpn-client"

maybe_install_packages openvpn

cp -p $OURDIR/$HOSTNAME.crt $OURDIR/$HOSTNAME.key /etc/openvpn/
cp -p $OURDIR/ca.crt /etc/openvpn

nmfqdn=`getfqdn $NETWORKMANAGER`

cat <<EOF > /etc/openvpn/server.conf
client
dev tun
proto udp
remote $nmfqdn 1194
resolv-retry infinite
nobind
persist-key
persist-tun
ca ca.crt
cert $HOSTNAME.crt
key $HOSTNAME.key
ns-cert-type server
comp-lzo
verb 3
EOF

#
# Get the server up
#
if [ ${HAVE_SYSTEMD} -eq 1 ]; then
    systemctl enable openvpn@server.service
    systemctl restart openvpn@server.service
else
    service openvpn restart
fi

logtend "vpn-client"

exit 0
