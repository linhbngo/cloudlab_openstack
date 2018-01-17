#!/bin/sh

DIRNAME=`dirname $0`

# Gotta know the rules!
if [ `id -u` -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Grab our libs
. "$DIRNAME/setup-lib.sh"

IMAGEDIR="$OURDIR/images"
if [ ! -d "$IMAGEDIR" ]; then
    mkdir -p "$IMAGEDIR"
fi
IMAGESETUPLOCKFILE="$IMAGEDIR/image-setup-lockfile"
IMAGEUPLOADCMDFILE="$IMAGEDIR/image-upload-commands.sh"

mount_image_etc() {
    _imgfile="$1"
    modprobe nbd max_part=8 > /dev/null 2>&1
    maxdevnum=`ls -1 /dev/nbd* | sed -e 's/\/dev\/nbd//' | sort -n | tail -1`
    if [ -z "$maxdevnum" ]; then
	maxdevnum=8
    fi
    success=0
    i=0
    while [ $success -eq 0 -a $i -lt $maxdevnum ]; do
	if [ ! -e /dev/nbd$i ]; then
	    i=`expr $i + 1`
	    continue
	fi

	qemu-nbd --connect=/dev/nbd$i "$_imgfile" > /dev/null 2>&1
	if [ $? -eq 0 ]; then
	    success=1
	    DEV=/dev/nbd$i
	    DEVPREFIX=/dev/nbd
	    DEVNUM=$i
	    partprobe /dev/nbd$i
	    break
	fi
	i=`expr $i + 1`
    done
    if [ ! $success -eq 1 ]; then
	fmt=`get_image_format $_imgfile`
	if [ "$fmt" = "raw" ]; then
	    # Try loopback mount
	    maxdevnum=`ls -1 /dev/loop* | sed -e 's/\/dev\/loop//' | sort -n | tail -1`
	    if [ -z "$maxdevnum" ]; then
		maxdevnum=8
	    fi
	    success=0
	    i=0
	    while [ $success -eq 0 -a $i -lt $maxdevnum ]; do
		if [ ! -e /dev/loop$i ]; then
		    i=`expr $i + 1`
		    continue
		fi

		losetup /dev/loop$i "$_imgfile" > /dev/null 2>&1
		if [ $? -eq 0 ]; then
		    success=1
		    partprobe /dev/loop$i
		    DEV=/dev/loop$i
		    DEVPREFIX=/dev/loop
		    DEVNUM=$i
		    break
		fi
		i=`expr $i + 1`
	    done
	fi

	if [ ! $success -eq 1 ]; then
	    /bin/false
	    return
	fi
    fi

    mntdir=`mktemp -d $IMAGEDIR/mnt.XXXX`

    # Mount the partition containing /etc/passwd
    success=0
    for part in `fdisk -l $DEV | grep ^\/dev | cut -f 1 -d ' '` ; do
	# First, check to see if there's a device mapper entry for this
	# device -- i.e., if it's got LVM stuff.
	pvscan --cache --activate ay $part > /dev/null 2>&1
	sdev=`echo $DEV | sed -n -e 's/^.*\/\([^\/]*\)$/\1/p'`
	spart=`echo $part | sed -n -e 's/^.*\/\([^\/]*\)$/\1/p'`
	dmnamefile=`ls -1 /sys/block/$sdev/$spart/holders/dm-*/dm/name`
	if [ -n "$dmnamefile" -a -f "$dmnamefile" ]; then
	    dmname=`cat $dmnamefile`
	    mount /dev/mapper/$dmname $mntdir > /dev/null 2>&1
	    if [ $? -eq 0 -a -f $mntdir/etc/passwd ]; then
		echo "$mntdir"
		return
	    fi
	    umount $mntdir
	else
	    mount $part $mntdir > /dev/null 2>&1
	    if [ $? -eq 0 -a -f $mntdir/etc/passwd ]; then
		echo "$mntdir"
		return
	    fi
	    umount $mntdir
	fi
    done

    # Cleanup on error
    rmdir $mntdir > /dev/null 2>&1
    grep -q nbd "$DEV"
    if [ $? -eq 0 ]; then
	qemu-nbd --disconnect $DEV > /dev/null 2>&1
    else
	losetup -d $DEV > /dev/null 2>&1
    fi
    echo ""
    /bin/false
}

umount_image() {
    mntdir="$1"
    # Try hard to get only the device name without the partition;
    # qemu-nbd can detach with partition device, but losetup needs only
    # the device, not a partition.
    dev=`mount | grep "$mntdir " | sed -n -e 's/^\([\/0-9A-Za-z_-]*\/[a-zA-Z_-]*[0-9]*\).* on .*$/\1/p'`
    if [ -z "$dev" ]; then
	# Fall back to the partition device.
	dev=`mount | grep "$mntdir " | sed -e 's/^\([^ ]*\) on .*$/\1/'`
    fi
    if [ -z "$dev" ]; then
	echo "*** ERROR: could not find device corresponding to $mntdir; umounting without detaching anyway!"
	umount "$mntdir"
	rmdir "$mntdir"
	/bin/false
	return
    fi
    
    umount "$mntdir"
    rmdir "$mntdir"
    grep -q nbd "$dev"
    if [ $? -eq 0 ]; then
	qemu-nbd --disconnect $dev > /dev/null 2>&1
    else
	losetup -d $dev > /dev/null 2>&1
    fi
}

fixup_mounted_image() {
    MNT="$1"
    _imgfile="$2"

    echo "*** $_imgfile: setting up sshd ..."
    grep -q '[# ]*PermitRootLogin .*' $MNT/etc/ssh/sshd_config
    if [ $? -eq 0 ]; then
	sed -i -e 's/^[# ]*PermitRootLogin .*$/PermitRootLogin without-password/' \
	    $MNT/etc/ssh/sshd_config
    else
	echo "PermitRootLogin without-password" >> $MNT/etc/ssh/sshd_config
    fi
    grep -q '[# ]*PasswordAuthentication .*' $MNT/etc/ssh/sshd_config
    if [ $? -eq 0 ]; then
	sed -i -e 's/^[# ]*PasswordAuthentication .*$/PasswordAuthentication yes/' \
	    $MNT/etc/ssh/sshd_config
    else
	echo "PasswordAuthentication yes" >> $MNT/etc/ssh/sshd_config
    fi

    echo "*** $_imgfile: modifying root password..."

    #cp -p $MNT/etc/shadow $IMAGEDIR/
    #cp -p $MNT/etc/passwd $IMAGEDIR/
    #cp -p $MNT/etc/group $IMAGEDIR/

    echo "*** $_imgfile: fixing root password ..."
    #sed -i -e "s@root:[^:]*:@root:${ADMIN_PASS_HASH}:@" $MNT/etc/shadow
    sed -i -e "s@root:[^:]*:@root:!:@" $MNT/etc/shadow

    grep -q Ubuntu $MNT/etc/lsb-release
    if [ $? -eq 0 ]; then
	sshvers=`dpkg-query --admindir $MNT/var/lib/dpkg -W --showformat='${Version}' openssh-server | sed -n -r -e 's/^([0-9]:)*([^:])([^:]*)$/\2/p'`
	if [ -z "$sshvers" ]; then
	    sshvers=0
	fi
	if [ $sshvers -ge 7 ]; then
	    echo "*** Adding support for dss keys for SSH version >= $sshvers"
	    echo "PubkeyAcceptedKeyTypes +ssh-dss" >> $MNT/etc/ssh/sshd_config
	fi
	echo "*** $_imgfile: fixing ubuntu password ..."
	grep ^ubuntu $MNT/etc/passwd
	if [ $? -eq 0 ]; then
	    sed -i -e "s@ubuntu:[^:]*:@ubuntu:${ADMIN_PASS_HASH}:@" \
		$MNT/etc/shadow
	else
	    # Have to add the user so that the passwd is actually set...
	    echo "ubuntu:x:1000:1000:Ubuntu:/home/ubuntu:/bin/bash" \
		 >> $MNT/etc/passwd
	    echo "ubuntu:!:16731:0:99999:7:::" >> $MNT/etc/shadow
	    echo "ubuntu:x:1000:" >> $MNT/etc/group
	    echo "ubuntu:!::" >> $MNT/etc/gshadow

	    mkdir -p $MNT/home/ubuntu
	    chown 1000:1000 $MNT/home/ubuntu

	    sed -i -e "s@ubuntu:[^:]*:@ubuntu:${ADMIN_PASS_HASH}:@" \
		$MNT/etc/shadow
	fi

	echo "*** $_imgfile: modifying to support multiple NICs..."

	mkdir -p $MNT/etc/udev/rules.d
	cat <<EOF > $MNT/etc/udev/rules.d/99-auto-network.rules
ACTION=="add", SUBSYSTEM=="net", NAME!="", NAME=="eth*|en*|sl*|ww*|wl*", RUN+="/usr/local/bin/auto-udev-network-interfaces-handler add \$name \$attr{address}"
ACTION=="add", SUBSYSTEM=="net", NAME=="", KERNEL=="eth*|en*|sl*|ww*|wl*", RUN+="/usr/local/bin/auto-udev-network-interfaces-handler add \$kernel \$attr{address}"
EOF
	mkdir -p $MNT/usr/local/bin
	cat <<'EOF' >$MNT/usr/local/bin/auto-udev-network-interfaces-handler
#!/bin/sh

PREFIX='auto-udev'
RUNDIR='/run/auto-udev-interfaces.d'

command="$1"
iface="$2"
addr="$3"
stripaddr=`echo $addr | sed -e 's/://g'`

if [ ! -d $RUNDIR ]; then
    mkdir -p $RUNDIR
fi

if [ "$command" = "add" ]; then
    echo "# Added by autocloud" >$RUNDIR/$PREFIX-$iface
    echo "auto $iface" >$RUNDIR/$PREFIX-$iface
    echo "iface $iface inet dhcp" >>$RUNDIR/$PREFIX-$iface
    #ifconfig "$iface" up
elif [ "$command" = "remove" ]; then
    if [ -f $RUNDIR/$PREFIX-$iface-$stripaddr ]; then
        rm -f $RUNDIR/$PREFIX-$iface
    fi
elif [ "$command" = "reset" ]; then
    rm -f $RUNDIR/$PREFIX-*
else
    exit 1
fi

exit 0
EOF
	chmod 755 $MNT/usr/local/bin/auto-udev-network-interfaces-handler

	mkdir -p $MNT/etc/dhcp/dhclient-enter-hooks.d
	cat << 'EOF' > $MNT/etc/dhcp/dhclient-enter-hooks.d/no-default-route
#!/bin/sh

PREFIX='auto-udev'
RUNDIR='/run/auto-udev-interfaces.d'

grep -i autocloud $RUNDIR/$PREFIX-$interface
if [ $? -eq 0 ]; then
    case "$reason" in
        BOUND|RENEW|REBIND|REBOOT|TIMEOUT)
            unset new_routers
            unset new_classless_static_routes
            unset new_host_name
            unset new_domain_name
            unset new_domain_name_servers
            ;;
    esac
fi
EOF
	chmod 755 $MNT/etc/dhcp/dhclient-enter-hooks.d/no-default-route

	cat <<EOF >> $MNT/etc/network/interfaces
source-directory /run/auto-udev-interfaces.d
EOF

	#
	# Ok, there is some delay with local-filesystems not finishing
	# mounting until after the cloud-utils have blocked up the
	# system :(.  So, remove this dependency.  You can see why the
	# Ubuntu people have it in general, but it will never bother us
	# in this VM image!
	#
	if [ -f $MNT/etc/init/networking.conf ]; then
	    #sed -i -e 's/^start on (local-filesystems$/start on (mounted MOUNTPOINT=\/ and mounted MOUNTPOINT=\/sys and mounted MOUNTPOINT=\/proc and mounted MOUNTPOINT=\/run/' $MNT/etc/init/networking.conf
	    sed -i -e 's/^start on (local-filesystems$/start on (mounted MOUNTPOINT=\//' $MNT/etc/init/networking.conf
	fi

    fi

    if [ -f $MNT/etc/centos-release ]; then
	echo "*** $_imgfile: fixing centos password ..."
	grep ^centos $MNT/etc/passwd
	if [ $? -eq 0 ]; then
	    sed -i -e "s@centos:[^:]*:@centos:${ADMIN_PASS_HASH}:@" \
		$MNT/etc/shadow
	else
	    # Have to add the user so that the passwd is actually set...
	    echo "centos:x:1000:1000:Centos:/home/centos:/bin/bash" \
		 >> $MNT/etc/passwd
	    echo "centos:!:16731:0:99999:7:::" >> $MNT/etc/shadow
	    echo "centos:x:1000:" >> $MNT/etc/group
	    echo "centos:!::" >> $MNT/etc/gshadow

	    mkdir -p $MNT/home/centos
	    chown 1000:1000 $MNT/home/centos

	    sed -i -e "s@centos:[^:]*:@centos:${ADMIN_PASS_HASH}:@" \
		$MNT/etc/shadow
	fi

    fi

    if [ -f $MNT/etc/redhat-release ]; then
	echo "*** $_imgfile: fixing fedora password ..."
	grep ^fedora $MNT/etc/passwd
	if [ $? -eq 0 ]; then
	    sed -i -e "s@fedora:[^:]*:@fedora:${ADMIN_PASS_HASH}:@" \
		$MNT/etc/shadow
	else
	    # Have to add the user so that the passwd is actually set...
	    echo "fedora:x:1000:1000:Fedora:/home/fedora:/bin/bash" \
		 >> $MNT/etc/passwd
	    echo "fedora:!:16731:0:99999:7:::" >> $MNT/etc/shadow
	    echo "fedora:x:1000:" >> $MNT/etc/group
	    echo "fedora:!::" >> $MNT/etc/gshadow

	    mkdir -p $MNT/home/fedora
	    chown 1000:1000 $MNT/home/fedora

	    sed -i -e "s@fedora:[^:]*:@fedora:${ADMIN_PASS_HASH}:@" \
		$MNT/etc/shadow
	fi
    fi

    if [ -f $MNT/etc/centos-release -o -f $MNT/etc/redhat-release ]; then
	# Add a special fake network device that basically calls
	# dhclient on any non-eth0 and non-lo device.
	cat << 'EOF' > $MNT/etc/sysconfig/network-scripts/ifcfg-eth99
#
# HACK: run dhclient on all interfaces (except eth0 and lo; we assume
# any cloud image will configure those two devices).
#
# Note that this file's name (eth99) cannot overlap with an actual
# existing interface or dhclient will loop.  dhclient-script invokes
# the source-config function which sources the ifcfg-ethN file.  Thus
# if this script were called "ifcfg-eth0" and eth0 was the DHCPable
# interface, we would wind up recursively invoking dhclient.
#
# This is actually invoked from /etc/sysconfig/network-scripts/ifup-autocloud
# not directly from here, since /etc/init.d/network stop sources this file
# without telling it why it was sourced.  So, we define a custom ifup script
# instead, triggered by the DEVICETYPE variable being set to autocloud, 
# and by creating /etc/sysconfig/network-scripts/ifup-autocloud.
#

DEVICE="eth99"
TYPE="ethernet"
DEVICETYPE="autocloud"
ONBOOT="yes"
EOF

	cat << 'EOF' > $MNT/etc/sysconfig/network-scripts/ifup-autocloud
#/bin/sh -
#
# HACK: run dhclient on all interfaces except eth0 and lo.
#
# (also see comments in /etc/sysconfig/network-scripts/ifcfg-eth99 to
# understand how this gets invoked)
#

DEVICE="eth99"

interfaces=`ip -o link show | grep 'link/ether' | sed -e 's/^[^:]*:[ ]*\([^:]*\):.*$/\1/'`

#
# Run dhclient on each.
#
for iface in $interfaces ; do
    [ "$iface" = "eth0" -o "$iface" = "lo" -o "$iface" = "lo0" ] && continue

    if [ ! -f /etc/sysconfig/network-scripts/ifcfg-$iface ]; then
        cat << IOF > /etc/sysconfig/network-scripts/ifcfg-$iface
# Added by autocloud
DEVICE="$iface"
BOOTPROTO="dhcp"
# Not on boot because this script manually runs ifup
ONBOOT="no"
TYPE="ethernet"
PERSISTENT_DHCLIENT="yes"
IOF
    fi
    ifup $iface
done

exit 0
EOF
	chmod 755 $MNT/etc/sysconfig/network-scripts/ifup-autocloud

	mkdir -p $MNT/etc/dhcp/dhclient-enter-hooks.d
	cat << 'EOF' > $MNT/etc/dhcp/dhclient-enter-hooks.d/no-default-route
#!/bin/sh

grep -i autocloud /etc/sysconfig/network-scripts/ifcfg-$interface
if [ $? -eq 0 ]; then
    case "$reason" in
        BOUND|RENEW|REBIND|REBOOT|TIMEOUT)
            unset new_routers
            unset new_classless_static_routes
            unset new_host_name
            unset new_domain_name
            unset new_domain_name_servers
            ;;
    esac
fi
EOF
	chmod 755 $MNT/etc/dhcp/dhclient-enter-hooks.d/no-default-route
	#
	# Ok, copy our hooks into every possible place dhclient might
	# look, but don't overwrite any native dhclient-enter-hooks
	# files.  (We have observed that sometimes dhclient does not
	# call the hooks in the .d directories -- weird).
	#
	mkdir -p $MNT/etc/dhcp3/dhclient-enter-hooks.d
	cp $MNT/etc/dhcp/dhclient-enter-hooks.d/no-default-route \
	    $MNT/etc/dhcp3/dhclient-enter-hooks.d/no-default-route
	if [ ! -f $MNT/etc/dhcp/dhclient-enter-hooks ]; then
	    cp $MNT/etc/dhcp/dhclient-enter-hooks.d/no-default-route \
		$MNT/etc/dhcp/dhclient-enter-hooks
	fi
	if [ ! -f $MNT/etc/dhcp3/dhclient-enter-hooks ]; then
	    cp $MNT/etc/dhcp/dhclient-enter-hooks.d/no-default-route \
		$MNT/etc/dhcp3/dhclient-enter-hooks
	fi
	sshvers=`rpm --root $MNT --queryformat '%{VERSION}' -q openssh | sed -n -r -e 's/^([^.]*)(.*)$/\1/p'`
	if [ -z "$sshvers" ]; then
	    sshvers=0
	fi
	if [ $sshvers -ge 7 ]; then
	    echo "*** Adding support for dss keys for SSH version >= $sshvers"
	    echo "PubkeyAcceptedKeyTypes +ssh-dss" >> $MNT/etc/ssh/sshd_config
	fi
    fi

    if [ -f $MNT/etc/cloud/cloud.cfg ]; then
	# permit root login!!
	sed -i -e 's/^disable_root: true$/disable_root: false/' \
	    $MNT/etc/cloud/cloud.cfg

	# don't overwrite the Ubuntu passwd we just hacked in
	sed -i -e 's/^\(.*lock_passwd:\)\(.*\)$/\1 false/' \
	    $MNT/etc/cloud/cloud.cfg
    fi

    /bin/true
}

fixup_image() {
    _imgfile="$1"
    MNT=`mount_image_etc "$_imgfile"`
    if [ -z "$MNT" ]; then
	echo "ERROR: could not mount $_imgfile !"
	/bin/false
	return
    fi

    fixup_mounted_image "$MNT" "$_imgfile"

    umount_image "$MNT"
}

#
# We only support xz/lzma/gz .
#
extract_image() {
    _imgfile="$1"
    _force="$2"
    if [ -n "$_force" -a "$_force" = "1" ]; then
	forcearg="-f"
    else
	forcearg=""
    fi

    echo "$_imgfile" | grep -iq '\(\.xz\)\|\(\.lzma\)'
    if [ $? -eq 0 ]; then
	xz --decompress -k $forcearg "$_imgfile"
	newfile=`echo "$_imgfile" | sed -e 's/\(\.xz\|\.lzma\)//i'`
	echo "$newfile"
	return
    fi
    echo "$_imgfile" | grep -iq '\(\.gz\)'
    if [ $? -eq 0 ]; then
	gzip -d -k $forcearg "$_imgfile"
	newfile=`echo "$_imgfile" | sed -e 's/\(\.gz\)//i'`
	echo "$newfile"
	return
    fi

    echo "$_imgfile"
    return
}

#
# We only support qcow,vmware,vhd,raw.
#
get_image_format() {
    _imgfile="$1"

    output=`file $_imgfile`
    echo "$output" | grep -iq qcow
    if [ $? -eq 0 ]; then
	echo "qcow2"
	return
    fi
    echo "$output" | grep -iq vmware
    if [ $? -eq 0 ]; then
	echo "vmdk"
	return
    fi
    echo "$output" | grep -iq vhd
    if [ $? -eq 0 ]; then
	echo "vhd"
	return
    fi
    echo "$output" | grep -iq 'MBR boot sector'
    if [ $? -eq 0 ]; then
	echo "raw"
	return
    fi

    echo "raw"
}

sched_image() {
    _imgfile="$1"
    _imgname="$2"

    if [ -z "$_imgname" ]; then
	_imgname="$_imgfile"
    fi
    
    touch $IMAGEUPLOADCMDFILE
    chmod 755 $IMAGEUPLOADCMDFILE

    GLANCEOPTS=""
    if [ "$OSCODENAME" = "juno" -o "$OSCODENAME" = "kilo" ]; then
	GLANCEOPTS="--is-public True"
    fi

    format=`get_image_format $_imgfile`

    echo "glance image-create --name '${_imgname}' ${GLANCEOPTS} --disk-format $format --container-format bare --progress --file '$_imgfile'" >> $IMAGEUPLOADCMDFILE
}

upload_image() {
    _imgfile="$1"
    _imgname="$2"

    if [ -z "$_imgname" ]; then
	_imgname="$_imgfile"
    fi
    
    GLANCEOPTS=""
    if [ "$OSCODENAME" = "juno" -o "$OSCODENAME" = "kilo" ]; then
	GLANCEOPTS="--is-public True"
    fi

    format=`get_image_format $_imgfile`

    glance image-create --name "${_imgname}" ${GLANCEOPTS} --disk-format $format --container-format bare --progress --file "$_imgfile"
}

#
# Drag in the arch-specific customizations, if any.
#
ARCH=`uname -m`
if [ "$ARCH" = "aarch64" ] ; then
    if [ -f $DIRNAME/setup-images-lib-aarch64.sh ]; then
	. $DIRNAME/setup-images-lib-aarch64.sh
    fi
else
    if [ -f $DIRNAME/setup-images-lib-x86_64.sh ]; then
	. $DIRNAME/setup-images-lib-x86_64.sh
    fi
fi
