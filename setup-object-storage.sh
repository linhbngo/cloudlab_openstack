#!/bin/sh

##
## Setup a OpenStack object storage node.
##

set -x

# Gotta know the rules!
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Grab our libs
. "`dirname $0`/setup-lib.sh"

if [ "$HOSTNAME" != "$OBJECTHOST" ]; then
    exit 0;
fi

if [ -f $OURDIR/setup-object-host-done ]; then
    exit 0
fi

logtstart "object-storage"

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi
if [ -f $LOCALSETTINGS ]; then
    . $LOCALSETTINGS
fi

maybe_install_packages xfsprogs rsync

#
# First try to make LVM volumes; fall back to loop device in /storage.  We use
# /storage for swift later, so we make the dir either way.
#

mkdir -p /storage
if [ -z "$LVM" ] ; then
    LVM=1
    VGNAME="openstack-volumes"
    MKEXTRAFS_ARGS="-l -v ${VGNAME} -m util -z 1024"
    # On Cloudlab ARM machines, there is no second disk nor extra disk space
    # Well, now there's a new partition layout; try it.
    if [ "$ARCH" = "aarch64" ]; then
	maybe_install_packages gdisk
	sgdisk -i 1 /dev/sda
	if [ $? -eq 0 ] ; then
	    sgdisk -N 2 /dev/sda
	    if [ $? -eq 0 ] ; then
		partprobe
		# Add the second partition specifically
		MKEXTRAFS_ARGS="${MKEXTRAFS_ARGS} -s 2"
	    else
		MKEXTRAFS_ARGS=""
		LVM=0
	    fi
	else
	    MKEXTRAFS_ARGS=""
	    LVM=0
	fi
    fi

    /usr/local/etc/emulab/mkextrafs.pl ${MKEXTRAFS_ARGS}
    if [ $? -ne 0 ]; then
	/usr/local/etc/emulab/mkextrafs.pl ${MKEXTRAFS_ARGS} -f
	if [ $? -ne 0 ]; then
	    /usr/local/etc/emulab/mkextrafs.pl -f /storage
	    LVM=0
	fi
    fi
fi

LDEVS=""
if [ $LVM -eq 0 ] ; then
    dd if=/dev/zero of=/storage/swiftv1 bs=32768 count=131072
    LDEV=`losetup -f`
    losetup $LDEV /storage/swiftv1
    LDEVS="${LDEV}"
    dd if=/dev/zero of=/storage/swiftv1-2 bs=32768 count=131072
    LDEV=`losetup -f`
    losetup $LDEV /storage/swiftv1-2
    LDEVS="${LDEVS} ${LDEV}"
else
    lvcreate -n swiftv1 -L 4G $VGNAME
    LDEV=/dev/${VGNAME}/swiftv1
    LDEVS="${LDEV}"
    lvcreate -n swiftv1-2 -L 4G $VGNAME
    LDEV=/dev/${VGNAME}/swiftv1-2
    LDEVS="${LDEVS} ${LDEV}"
fi

mkdir -p /storage/mnt/swift
for ldev in $LDEVS ; do
    base=`basename $ldev`
    mkfs.xfs $ldev
    cat <<EOF >> /etc/fstab
$ldev /storage/mnt/swift/$base xfs noatime,nodiratime,nobarrier,logbufs=8 0 2
EOF
    mkdir -p /storage/mnt/swift/$base
    mount /storage/mnt/swift/$base
done

cat <<EOF >> /etc/rsyncd.conf
uid = swift
gid = swift
log file = /var/log/rsyncd.log
pid file = /var/run/rsyncd.pid
address = $MGMTIP

[account]
max connections = 8
path = /storage/mnt/swift
read only = false
lock file = /var/lock/account.lock

[container]
max connections = 8
path = /storage/mnt/swift
read only = false
lock file = /var/lock/container.lock

[object]
max connections = 8
path = /storage/mnt/swift
read only = false
lock file = /var/lock/object.lock
EOF

cat <<EOF >> /etc/default/rsync
RSYNC_ENABLE=true
EOF

service_enable rsync
service_restart rsync
service_start rsync

mkdir -p /var/log/swift
chown -R syslog.adm /var/log/swift

maybe_install_packages swift swift-account swift-container swift-object

wget -O /etc/swift/account-server.conf \
    "https://git.openstack.org/cgit/openstack/swift/plain/etc/account-server.conf-sample?h=stable/${OSCODENAME}"
if [ ! $? -eq 0 ]; then
    # Try the EOL version...
    wget -O /etc/swift/account-server.conf \
	"https://git.openstack.org/cgit/openstack/swift/plain/etc/account-server.conf-sample?h=${OSCODENAME}-eol"
fi

wget -O /etc/swift/container-server.conf \
    "https://git.openstack.org/cgit/openstack/swift/plain/etc/container-server.conf-sample?h=stable/${OSCODENAME}"
if [ ! $? -eq 0 ]; then
    # Try the EOL version...
    wget -O /etc/swift/container-server.conf \
	"https://git.openstack.org/cgit/openstack/swift/plain/etc/container-server.conf-sample?h=${OSCODENAME}-eol"
fi

wget -O /etc/swift/object-server.conf \
    "https://git.openstack.org/cgit/openstack/swift/plain/etc/object-server.conf-sample?h=stable/${OSCODENAME}"
if [ ! $? -eq 0 ]; then
    # Try the EOL version...
    wget -O /etc/swift/object-server.conf \
	"https://git.openstack.org/cgit/openstack/swift/plain/etc/object-server.conf-sample?h=${OSCODENAME}-eol"
fi

if [ $OSVERSION -ge $OSKILO ]; then
    wget -O /etc/swift/container-reconciler.conf \
	"https://git.openstack.org/cgit/openstack/swift/plain/etc/container-reconciler.conf-sample?h=stable/${OSCODENAME}"
    if [ ! $? -eq 0 ]; then
        # Try the EOL version...
	wget -O /etc/swift/container-reconciler.conf \
	    "https://git.openstack.org/cgit/openstack/swift/plain/etc/container-reconciler.conf-sample?h=${OSCODENAME}-eol"
    fi
    wget -O /etc/swift/object-expirer.conf \
	"https://git.openstack.org/cgit/openstack/swift/plain/etc/object-expirer.conf-sample?h=stable/${OSCODENAME}"
    if [ ! $? -eq 0 ]; then
        # Try the EOL version...
	wget -O /etc/swift/object-expirer.conf \
	    "https://git.openstack.org/cgit/openstack/swift/plain/etc/object-expirer.conf-sample?h=${OSCODENAME}-eol"
    fi
fi

crudini --set /etc/swift/account-server.conf DEFAULT bind_ip $MGMTIP
crudini --set /etc/swift/account-server.conf DEFAULT bind_port 6002
crudini --set /etc/swift/account-server.conf DEFAULT user swift
crudini --set /etc/swift/account-server.conf DEFAULT swift_dir /etc/swift
crudini --set /etc/swift/account-server.conf DEFAULT devices /storage/mnt/swift
if [ $OSVERSION -ge $OSLIBERTY ]; then
    crudini --set /etc/swift/account-server.conf DEFAULT mount_check true
fi

crudini --set /etc/swift/account-server.conf pipeline:main \
    pipeline 'healthcheck recon account-server'
crudini --set /etc/swift/account-server.conf filter:recon \
    use 'egg:swift#recon'
crudini --set /etc/swift/account-server.conf filter:recon \
    recon_cache_path /var/cache/swift

crudini --set /etc/swift/account-server.conf DEFAULT log_facility LOG_LOCAL1
crudini --set /etc/swift/account-server.conf DEFAULT log_level INFO
crudini --set /etc/swift/account-server.conf DEFAULT log_name swift-account
crudini --set /etc/swift/account-server.conf app:account-server log_facility LOG_LOCAL1
crudini --set /etc/swift/account-server.conf app:account-server log_level INFO
crudini --set /etc/swift/account-server.conf app:account-server log_name swift-account
crudini --set /etc/swift/account-server.conf account-replicator log_facility LOG_LOCAL1
crudini --set /etc/swift/account-server.conf account-replicator log_level INFO
crudini --set /etc/swift/account-server.conf account-replicator log_name swift-account-replicator
crudini --set /etc/swift/account-server.conf account-auditor log_facility LOG_LOCAL1
crudini --set /etc/swift/account-server.conf account-auditor log_level INFO
crudini --set /etc/swift/account-server.conf account-auditor log_name swift-account-auditor
crudini --set /etc/swift/account-server.conf account-reaper log_facility LOG_LOCAL1
crudini --set /etc/swift/account-server.conf account-reaper log_level INFO
crudini --set /etc/swift/account-server.conf account-reaper log_name swift-account-reaper

echo 'if $programname == "swift-account" then { action(type="omfile" file="/var/log/swift/swift-account.log") }' >> /etc/rsyslog.d/99-swift.conf

crudini --set /etc/swift/container-server.conf DEFAULT bind_ip $MGMTIP
crudini --set /etc/swift/container-server.conf DEFAULT bind_port 6001
crudini --set /etc/swift/container-server.conf DEFAULT user swift
crudini --set /etc/swift/container-server.conf DEFAULT swift_dir /etc/swift
crudini --set /etc/swift/container-server.conf DEFAULT devices /storage/mnt/swift
if [ $OSVERSION -ge $OSLIBERTY ]; then
    crudini --set /etc/swift/container-server.conf DEFAULT mount_check true
fi

crudini --set /etc/swift/container-server.conf pipeline:main \
    pipeline 'healthcheck recon container-server'
crudini --set /etc/swift/container-server.conf filter:recon \
    use 'egg:swift#recon'
crudini --set /etc/swift/container-server.conf filter:recon \
    recon_cache_path /var/cache/swift

crudini --set /etc/swift/container-server.conf DEFAULT log_facility LOG_LOCAL1
crudini --set /etc/swift/container-server.conf DEFAULT log_level INFO
crudini --set /etc/swift/container-server.conf DEFAULT log_name swift-container
crudini --set /etc/swift/container-server.conf app:container-server log_facility LOG_LOCAL1
crudini --set /etc/swift/container-server.conf app:container-server log_level INFO
crudini --set /etc/swift/container-server.conf app:container-server log_name swift-container
crudini --set /etc/swift/container-server.conf container-replicator log_facility LOG_LOCAL1
crudini --set /etc/swift/container-server.conf container-replicator log_level INFO
crudini --set /etc/swift/container-server.conf container-replicator log_name swift-container-replicator
crudini --set /etc/swift/container-server.conf container-updater log_facility LOG_LOCAL1
crudini --set /etc/swift/container-server.conf container-updater log_level INFO
crudini --set /etc/swift/container-server.conf container-updater log_name swift-container-updater
crudini --set /etc/swift/container-server.conf container-auditor log_facility LOG_LOCAL1
crudini --set /etc/swift/container-server.conf container-auditor log_level INFO
crudini --set /etc/swift/container-server.conf container-auditor log_name swift-container-auditor
crudini --set /etc/swift/container-server.conf container-sync log_facility LOG_LOCAL1
crudini --set /etc/swift/container-server.conf container-sync log_level INFO
crudini --set /etc/swift/container-server.conf container-sync log_name swift-container-sync

echo 'if $programname == "swift-container" then { action(type="omfile" file="/var/log/swift/swift-container.log") }' >> /etc/rsyslog.d/99-swift.conf

crudini --set /etc/swift/object-server.conf DEFAULT bind_ip $MGMTIP
crudini --set /etc/swift/object-server.conf DEFAULT bind_port 6000
crudini --set /etc/swift/object-server.conf DEFAULT user swift
crudini --set /etc/swift/object-server.conf DEFAULT swift_dir /etc/swift
crudini --set /etc/swift/object-server.conf DEFAULT devices /storage/mnt/swift
if [ $OSVERSION -ge $OSLIBERTY ]; then
    crudini --set /etc/swift/object-server.conf DEFAULT mount_check true
fi

crudini --set /etc/swift/object-server.conf pipeline:main \
    pipeline 'healthcheck recon object-server'
crudini --set /etc/swift/object-server.conf filter:recon \
    use 'egg:swift#recon'
crudini --set /etc/swift/object-server.conf filter:recon \
    recon_cache_path /var/cache/swift
if [ $OSVERSION -ge $OSKILO ]; then
    crudini --set /etc/swift/object-server.conf filter:recon \
	recon_lock_path /var/lock
fi

crudini --set /etc/swift/object-server.conf DEFAULT log_facility LOG_LOCAL1
crudini --set /etc/swift/object-server.conf DEFAULT log_level INFO
crudini --set /etc/swift/object-server.conf DEFAULT log_name swift-object
crudini --set /etc/swift/object-server.conf app:object-server log_facility LOG_LOCAL1
crudini --set /etc/swift/object-server.conf app:object-server log_level INFO
crudini --set /etc/swift/object-server.conf app:object-server log_name swift-object
crudini --set /etc/swift/object-server.conf object-replicator log_facility LOG_LOCAL1
crudini --set /etc/swift/object-server.conf object-replicator log_level INFO
crudini --set /etc/swift/object-server.conf object-replicator log_name swift-object-replicator
crudini --set /etc/swift/object-server.conf object-reconstructor log_facility LOG_LOCAL1
crudini --set /etc/swift/object-server.conf object-reconstructor log_level INFO
crudini --set /etc/swift/object-server.conf object-reconstructor log_name swift-object-reconstructor
crudini --set /etc/swift/object-server.conf object-updater log_facility LOG_LOCAL1
crudini --set /etc/swift/object-server.conf object-updater log_level INFO
crudini --set /etc/swift/object-server.conf object-updater log_name swift-object-updater
crudini --set /etc/swift/object-server.conf object-auditor log_facility LOG_LOCAL1
crudini --set /etc/swift/object-server.conf object-auditor log_level INFO
crudini --set /etc/swift/object-server.conf object-auditor log_name swift-object-auditor

echo 'if $programname == "swift-object" then { action(type="omfile" file="/var/log/swift/swift-object.log") }' >> /etc/rsyslog.d/99-swift.conf

chown -R swift:swift /storage/mnt/swift

mkdir -p /var/cache/swift
chown -R swift:swift /var/cache/swift

if [ ${HAVE_SYSTEMD} -eq 0 ]; then
    swift-init all start
    service rsyslog restart
else
    service_restart rsyslog
    service_restart swift-account
    service_enable swift-proxy
    service_restart swift-proxy
    service_enable swift-account
    service_restart swift-account-auditor
    service_enable swift-account-auditor
    service_restart swift-account-reaper
    service_enable swift-account-reaper
    service_restart swift-account-replicator
    service_enable swift-account-replicator
    service_restart swift-container
    service_enable swift-container
    service_restart swift-container-auditor
    service_enable swift-container-auditor
    service_restart swift-container-replicator
    service_enable swift-container-replicator
    service_restart swift-container-sync
    service_enable swift-container-sync
    service_restart swift-container-updater
    service_enable swift-container-updater
    service_restart swift-object
    service_enable swift-object
    service_restart swift-object-auditor
    service_enable swift-object-auditor
    service_restart swift-object-replicator
    service_enable swift-object-replicator
    service_restart swift-object-updater
    service_enable swift-object-updater
fi

touch $OURDIR/setup-object-host-done

logtend "object-storage"

exit 0
