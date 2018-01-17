#!/bin/sh

DIRNAME=`dirname $0`

#
# Setup our core vars
#
OURDIR=/root/setup
SETTINGS=$OURDIR/settings
LOCALSETTINGS=$OURDIR/settings.local
TOPOMAP=$OURDIR/topomap
BOOTDIR=/var/emulab/boot
TMCC=/usr/local/etc/emulab/tmcc

# Setup time logging stuff early
TIMELOGFILE=$OURDIR/setup-time.log
FIRSTTIME=0
if [ ! -f $OURDIR/setup-lib-first ]; then
    touch $OURDIR/setup-lib-first
    FIRSTTIME=`date +%s`
fi

logtstart() {
    area=$1
    varea=`echo $area | sed -e 's/[^a-zA-Z_0-9]/_/g'`
    stamp=`date +%s`
    date=`date`
    eval "LOGTIMESTART_$varea=$stamp"
    echo "START $area $stamp $date" >> $TIMELOGFILE
}

logtend() {
    area=$1
    #varea=${area//-/_}
    varea=`echo $area | sed -e 's/[^a-zA-Z_0-9]/_/g'`
    stamp=`date +%s`
    date=`date`
    eval "tss=\$LOGTIMESTART_$varea"
    tsres=`expr $stamp - $tss`
    resmin=`perl -e 'print '"$tsres"' / 60.0 . "\n"'`
    echo "END $area $stamp $date" >> $TIMELOGFILE
    echo "TOTAL $area $tsres $resmin" >> $TIMELOGFILE
}

if [ $FIRSTTIME -ne 0 ]; then
    logtstart "libfirsttime"
fi

mkdir -p $OURDIR
touch $SETTINGS
touch $LOCALSETTINGS
cd $OURDIR

#LOCKFILE="lockfile -1 -r -1 "
LOCKFILE="lockfile-create --retry 65535 "
RMLOCKFILE="lockfile-remove "
PSWDGEN="openssl rand -hex 10"
SSH="ssh -o StrictHostKeyChecking=no"
SCP="scp -p -o StrictHostKeyChecking=no"

#
# Our default configuration
#
CONTROLLER="ctl"
NETWORKMANAGER="nm"
STORAGEHOST="ctl"
SHAREHOST="ctl"
OBJECTHOST="ctl"
COMPUTENODES=""
BAREMETALNODES=""
BLOCKNODES=""
OBJECTNODES=""
DATALAN="lan-1"
MGMTLAN="lan-2"
BLOCKLAN=""
OBJECTLAN=""
DATATUNNELS=1
DATAFLATLANS="lan-1"
DATAVLANS=""
DATAVXLANS=0
DATAOTHERLANS=""
USE_EXISTING_IPS=1
DO_APT_INSTALL=1
DO_APT_UPGRADE=0
DO_APT_DIST_UPGRADE=0
DO_APT_UPDATE=1
UBUNTUMIRRORHOST=""
UBUNTUMIRRORPATH=""
ENABLE_NEW_SERIAL_SUPPORT=0
DO_UBUNTU_CLOUDARCHIVE=0
DO_UBUNTU_CLOUDARCHIVE_STAGING=0
BUILD_AARCH64_FROM_CORE=0
DISABLE_SECURITY_GROUPS=0
DEFAULT_SECGROUP_ENABLE_SSH_ICMP=1
VERBOSE_LOGGING="False"
DEBUG_LOGGING="False"
SUPPORT_DYNAMIC_NODES=0
KEYSTONEAPIVERSION=""
TOKENTIMEOUT=14400
SESSIONTIMEOUT=14400
CEILOMETER_USE_WSGI=0
QUOTASOFF=1
# Off by default; seems to cause intermittent keystone unavailability.
KEYSTONEUSEMEMCACHE=0
# Off by default for Juno; on for Kilo and on by default.
KEYSTONEUSEWSGI=""
# On by default; users will have to take full disk images of the
# compute nodes if they have this enabled.
COMPUTE_EXTRA_NOVA_DISK_SPACE="1"
# Support linuxbridge plugin too, but still default to openvswitch.
ML2PLUGIN="openvswitch"
MANILADRIVER="generic"
EXTRAIMAGEURLS=""
LINUXBRIDGE_STATIC=0
# If set to 1, and if OSRELEASE >= OSNEWTON, the physical machines will
# use the MGMTIP as the primary DNS server (in preference to the real
# control net DNS server).  The local domain will also be searched prior
# to the cluster's domain.
USE_DESIGNATE_AS_RESOLVER=1
# We are not currently using the ceilometer stats, and they do not work
# as of Pike due to the switch to Gnocchi as the measurement DB.
ENABLE_OPENSTACK_SLOTHD=0
# The input OpenStack release, if any, from profile params.
OSRELEASE=""

#
# We have an 'adminapi' user that gets a random password.  Then, we have
# the dashboard and instance password, that comes in from geni-lib/rspec as a
# hash, that defaults to the same as the old default profile.
#
# /root/setup/admin-openrc.sh contains the adminapi user, not admin!  We do it
# this way because we need a real passwd so that various CLI tools and openstack
# components have a real user/pass to auth as.
#
ADMIN_API='adminapi'
ADMIN_API_PASS=`$PSWDGEN`
ADMIN='admin'
ADMIN_PASS=''
#ADMIN_PASS_HASH='$6$kOIVUcvsnrD/hETx$JahyKoIJf1EFNI2AWCtfzn3ZBoBfaJrRQkjC0kW6VkTwPI9K3TtEWTh/axrHP.e5mmcM96/bTQs1.e7HSKIk10'
ADMIN_PASS_HASH=''

SWAPPER=`cat $BOOTDIR/swapper`

##
## Are we updating?
##
if [ "x$UPDATING" = "x" ]; then
    UPDATING=0
elif [ ! $UPDATING -eq 0 ]; then
    $LOCKFILE $OURDIR/UPDATING
fi
# We might store any new nodes here
NEWNODELIST=""
# We might store any missing nodes here
OLDNODELIST=""

##
## Detect if this was a geni experiment
##
grep GENIUSER $SETTINGS
if [ ! $? -eq 0 ]; then
    geni-get slice_urn >/dev/null 2>&1
    if [ $? -eq 0 ]; then
	GENIUSER=1
	echo "GENIUSER=1" >> $SETTINGS
    else
	GENIUSER=0
	echo "GENIUSER=0" >> $SETTINGS
    fi
else
    grep GENIUSER=1 $SETTINGS
    if [ $? -eq 0 ]; then
	GENIUSER=1
    else
	GENIUSER=0
    fi
fi

##
## Grab our geni creds, and create a GENI credential cert
##
#
# NB: force the install of python-m2crypto if geniuser
#
if [ $GENIUSER -eq 1 ]; then
    dpkg -s python-m2crypto >/dev/null 2>&1
    if [ ! $? -eq 0 ]; then
	apt-get install python-m2crypto
	# Keep trying again with updated cache forever;
	# we must have this package.
	success=$?
	while [ ! $success -eq 0 ]; do
	    apt-get update
	    apt-get install python-m2crypto
	    success=$?
	done
    fi

    if [ ! -e $OURDIR/geni.key ]; then
	geni-get key > $OURDIR/geni.key
	cat $OURDIR/geni.key | grep -q END\ .\*\PRIVATE\ KEY
	if [ $? -eq 0 ]; then
	    HAS_GENI_KEY=1
	else
	    HAS_GENI_KEY=0
	fi
    else
	HAS_GENI_KEY=1
    fi
    if [ ! -e $OURDIR/geni.certificate ]; then
	geni-get certificate > $OURDIR/geni.certificate
	cat $OURDIR/geni.certificate | grep -q END\ CERTIFICATE
	if [ $? -eq 0 ]; then
	    HAS_GENI_CERT=1
	else
	    HAS_GENI_CERT=0
	fi
    else
	HAS_GENI_CERT=1
    fi

    if [ ! -e /root/.ssl/encrypted.pem ]; then
	mkdir -p /root/.ssl
	chmod 600 /root/.ssl

	cat $OURDIR/geni.key > /root/.ssl/encrypted.pem
	cat $OURDIR/geni.certificate >> /root/.ssl/encrypted.pem
    fi

    if [ ! -e $OURDIR/manifests.xml -o $UPDATING -ne 0 ]; then
	if [ $HAS_GENI_CERT -eq 1 ]; then
	    python $DIRNAME/getmanifests.py $OURDIR/manifests
	else
	    # Fall back to geni-get
	    echo "WARNING: falling back to getting manifest from AM, not Portal -- multi-site experiments will not work fully!"
	    geni-get manifest > $OURDIR/manifests.0.xml
	fi
    fi

    if [ ! -e $OURDIR/encrypted_admin_pass ]; then
	cat /root/setup/manifests.0.xml | perl -e '@lines = <STDIN>; $all = join("",@lines); if ($all =~ /^.+<[^:]+:password[^>]*>([^<]+)<\/[^:]+:password>.+/igs) { print $1; }' > $OURDIR/encrypted_admin_pass
    fi

    if [ ! -e $OURDIR/decrypted_admin_pass -a -s $OURDIR/encrypted_admin_pass ]; then
	openssl smime -decrypt -inform PEM -inkey geni.key -in $OURDIR/encrypted_admin_pass -out $OURDIR/decrypted_admin_pass
    fi
fi

#
# Suck in user configuration overrides, if we haven't already
#
if [ ! -e $OURDIR/parameters ]; then
    touch $OURDIR/parameters
    if [ $GENIUSER -eq 1 ]; then
	cat $OURDIR/manifests.0.xml | sed -n -e 's/^[^<]*<[^:]*:parameter>\([^<]*\)<\/[^:]*:parameter>/\1/p' > $OURDIR/parameters
    fi
fi
. $OURDIR/parameters

#
# Ok, to be absolutely safe, if the ADMIN_PASS_HASH we got from params was "",
# and if admin pass wasn't sent as an encrypted string to us, we have we have
# to generate a random admin pass and hash it.
#
if [ "x${ADMIN_PASS_HASH}" = "x" ] ; then
    DEC_ADMIN_PASS=`cat $OURDIR/decrypted_admin_pass`
    if [ "x${DEC_ADMIN_PASS}" = "x" ]; then
	ADMIN_PASS=`$PSWDGEN`
	ADMIN_PASS_HASH="`echo \"${ADMIN_PASS}\" | openssl passwd -1 -stdin`"

	# Save it off so we can email the user -- because nobody has the
	# random pass we just generated!
	echo "${ADMIN_PASS}" > $OURDIR/random_admin_pass
    else
	ADMIN_PASS="${DEC_ADMIN_PASS}"
	ADMIN_PASS_HASH="`echo \"${ADMIN_PASS}\" | openssl passwd -1 -stdin`"
    fi

    #
    # Overwrite the params.
    #
    echo "ADMIN_PASS='${ADMIN_PASS}'" >> $OURDIR/parameters
    echo "ADMIN_PASS_HASH='${ADMIN_PASS_HASH}'" >> $OURDIR/parameters
fi

CREATOR=`cat $BOOTDIR/creator`
SWAPPER=`cat $BOOTDIR/swapper`
NODEID=`cat $BOOTDIR/nickname | cut -d . -f 1`
PNODEID=`cat $BOOTDIR/nodeid`
EEID=`cat $BOOTDIR/nickname | cut -d . -f 2`
EPID=`cat $BOOTDIR/nickname | cut -d . -f 3`
OURDOMAIN=`cat $BOOTDIR/mydomain`
NFQDN="`cat $BOOTDIR/nickname`.$OURDOMAIN"
PFQDN="`cat $BOOTDIR/nodeid`.$OURDOMAIN"
MYIP=`cat $BOOTDIR/myip`
EXTERNAL_NETWORK_INTERFACE=`cat $BOOTDIR/controlif`
HOSTNAME=`cat ${BOOTDIR}/nickname | cut -f1 -d.`
ARCH=`uname -m`

# Check if our init is systemd
dpkg-query -S /sbin/init | grep -q systemd
HAVE_SYSTEMD=`expr $? = 0`

#
# Figure out which OS/OpenStack this is.
#
OSJUNO=10
OSKILO=11
OSLIBERTY=12
OSMITAKA=13
OSNEWTON=14
OSOCATA=15
OSPIKE=16

. /etc/lsb-release
#
# Allow a specific release to trump the image defaults, maybe.
#
if [ ! "x$OSRELEASE" = "x" ]; then
    OSCODENAME="$OSRELEASE"
    if [ $OSCODENAME = "juno" ]; then OSVERSION=$OSJUNO ; fi
    if [ $OSCODENAME = "kilo" ]; then OSVERSION=$OSKILO ; fi
    if [ $OSCODENAME = "liberty" ]; then OSVERSION=$OSLIBERTY ; fi
    if [ $OSCODENAME = "mitaka" ]; then OSVERSION=$OSMITAKA ; fi
    if [ $OSCODENAME = "newton" ]; then OSVERSION=$OSNEWTON ; fi
    if [ $OSCODENAME = "ocata" ]; then OSVERSION=$OSOCATA ; fi
    if [ $OSCODENAME = "pike" ]; then OSVERSION=$OSPIKE ; fi

    #
    # We only use cloudarchive for LTS images!
    #
    echo "$DISTRIB_DESCRIPTION" | grep -qi LTS
    if [ $? -eq 0 ]; then
	DO_UBUNTU_CLOUDARCHIVE=1
    fi
elif [ ${DISTRIB_CODENAME} = "wily" ]; then
    OSCODENAME="liberty"
    OSVERSION=$OSLIBERTY
elif [ ${DISTRIB_CODENAME} = "vivid" ]; then
    OSCODENAME="kilo"
    OSVERSION=$OSKILO
elif [ ${DISTRIB_CODENAME} = "xenial" ]; then
    OSCODENAME="mitaka"
    OSVERSION=$OSMITAKA
else
    OSCODENAME="juno"
    OSVERSION=$OSJUNO
fi

#
# Default memcached fully on for Mitaka or greater.  Too slow without it.
#
if [ $OSVERSION -ge $OSMITAKA ]; then
    KEYSTONEUSEMEMCACHE=1
fi

if [ $OSVERSION -eq $OSJUNO ]; then
    REGION="regionOne"
else
    REGION="RegionOne"
fi

#
# Figure out if we got told to use keystone v2 or v3, or what our
# default should be if not.
#
if [ "x$KEYSTONEAPIVERSION" = "x3" ]; then
    # Let them force v3.
    KAPISTR='v3'
elif [ "$KEYSTONEAPIVERSION" != "2" -a $OSVERSION -ge $OSLIBERTY ]; then
    # If they didn't force v2 or v3, if we're on Liberty or higher, make
    # v3 the default
    KAPISTR='v3'
    KEYSTONEAPIVERSION=3
else
    # Otherwise, use version 2 by default (or choice)
    KEYSTONEAPIVERSION=2
    KAPISTR='v2.0'
fi

#
# Figure out Nova API string.
#
NAPISTR="v2"
if [ $OSVERSION -ge $OSMITAKA ]; then
    NAPISTR="v2.1"
fi

#
# Figure out if we got told to use keystone wsgi or not, or what our
# default should be if not.
#
if [ "x$KEYSTONEUSEWSGI" = "x" -a $OSVERSION -ge $OSKILO ]; then
    KEYSTONEUSEWSGI=1
elif [ "x$KEYSTONEUSEWSGI" = "x1" ]; then
    # Let them force WSGI
    KEYSTONEUSEWSGI=1
else
    KEYSTONEUSEWSGI=0
fi

#
# The keystone auth_token parameter names are project_domain_name and
# user_domain_name as of Mitaka.  The auth_token parameter name has
# also changed.
#
if [ $OSVERSION -ge $OSMITAKA ]; then
    PROJECT_DOMAIN_PARAM="project_domain_name"
    USER_DOMAIN_PARAM="user_domain_name"
    AUTH_TYPE_PARAM="auth_type"
else
    PROJECT_DOMAIN_PARAM="project_domain_id"
    USER_DOMAIN_PARAM="user_domain_id"
    AUTH_TYPE_PARAM="auth_plugin"
fi

#
# Set the database package name and driver string.
#
if [ $OSVERSION -ge $OSNEWTON ]; then
    DBDPACKAGE="python-pymysql"
    DBDSTRING="mysql+pymysql"
else
    DBDPACKAGE="python-mysqldb"
    DBDSTRING="mysql"
fi

if [ $GENIUSER -eq 1 ]; then
    SWAPPER_EMAIL=`geni-get slice_email`
else
    SWAPPER_EMAIL="$SWAPPER@$OURDOMAIN"
fi

if [ $GENIUSER -eq 1 ]; then
    PUBLICADDRS=`cat $OURDIR/manifests.*.xml | perl -e '$found = 0; while (<STDIN>) { if ($_ =~ /\<[\d\w:]*routable_pool [^\>\<]*\/>/) { print STDERR "DEBUG: found empty pool: $_\n"; next; } if ($_ =~ /\<[\d\w:]*routable_pool [^\>]*client_id=['"'"'"]'$NETWORKMANAGER'['"'"'"]/) { $found = 1; print STDERR "DEBUG: found: $_\n" } if ($found) { while ($_ =~ m/\<emulab:ipv4 address="([\d.]+)\" netmask=\"([\d\.]+)\"/g) { print "$1\n"; } } if ($found && $_ =~ /routable_pool\>/) { print STDERR "DEBUG: end found: $_\n"; $found = 0; } }' | xargs`
    PUBLICCOUNT=0
    for ip in $PUBLICADDRS ; do
	PUBLICCOUNT=`expr $PUBLICCOUNT + 1`
    done
else
    PUBLICADDRS=""
    PUBLICCOUNT=0
fi

#
# Grab our topomap so we can see how many nodes we have.
# NB: only safe to use topomap for non-fqdn things.
#
if [ ! -f $TOPOMAP -o $UPDATING -ne 0 ]; then
    if [ -f $TOPOMAP ]; then
	cp -p $TOPOMAP $TOPOMAP.old
    fi

    # First try via manifest; fall back to tmcc if necessary (although
    # that will break multisite exps with >1 second cluster node(s)).
    python2 $DIRNAME/manifest-to-topomap.py $OURDIR/manifests.0.xml > $TOPOMAP
    if [ ! $? -eq 0 ]; then
	echo "ERROR: could not extract topomap from manifest; aborting to tmcc"
	rm -f $TOPOMAP
	$TMCC topomap | gunzip > $TOPOMAP
    fi

    # Filter out blockstore nodes
    cat $TOPOMAP | grep -v '^bsnode,' > $TOPOMAP.no.bsnode
    mv $TOPOMAP.no.bsnode $TOPOMAP
    cat $TOPOMAP | grep -v '^bslink,' > $TOPOMAP.no.bslink
    mv $TOPOMAP.no.bslink $TOPOMAP
    if [ -f $TOPOMAP.old ]; then
	diff -u $TOPOMAP.old $TOPOMAP > $TOPOMAP.diff
	#
	# NB: this does assume that nodes either leave all the lans, or join
	# all the lans.  We don't try to distinguish anything else.
	#
	NEWNODELIST=`cat topomap.diff | sed -n -e 's/^\+\([a-zA-Z0-9\-]*\),.*:.*$/\1/p' | uniq | xargs`
	OLDNODELIST=`cat topomap.diff | sed -n -e 's/^\-\([a-zA-Z0-9\-]*\),.*:.*$/\1/p' | uniq | xargs`

	# Just remove the fqdn map and let it be recalculated below
	rm -f $OURDIR/fqdn.map
	rm -f $OURDIR/fqdn.physical.map
    fi
fi

#
# Since some of our testbeds only have one experiment interface per node,
# just do this little hack job -- if MGMTLAN was specified, but it's not in
# the topomap, we null it out and use the VPN Management setup instead.
#
if [ ! -z "$MGMTLAN" ] ; then
    cat $TOPOMAP | grep "$MGMTLAN"
    if [ $? -ne 0 ] ; then
	echo "*** Cannot find Management LAN $MGMTLAN ; falling back to VPN!"
	MGMTLAN=""
    fi
fi

#
# Create a map of node nickname to FQDN (and another one of pnode id to FQDN).
# This supports geni multi-site experiments.
#
if [ \( -s $OURDIR/manifests.xml \) -a \( ! \( -s $OURDIR/fqdn.map \) \) ]; then
    cat manifests.xml | tr -d '\n' | sed -e 's/<node /\n<node /g'  | sed -n -e "s/^<node [^>]*client_id=['\"]*\([^'\"]*\)['\"].*<host name=['\"]\([^'\"]*\)['\"].*$/\1\t\2/p" > $OURDIR/fqdn.map
    # Add a newline if we wrote anything.
    if [ -s $OURDIR/fqdn.map ]; then
	echo '' >> $OURDIR/fqdn.map
    fi
    # Filter out any blockstore nodes
    # XXX: this strategy doesn't work, because only the NM node makes
    # the fqdn.map file.  So, just look for bsnode for now.
    #BSNODES=`cat /var/emulab/boot/tmcc/storageconfig | sed -n -e 's/^.* HOSTID=\([^ \t]*\) .*$/\1/p' | xargs`
    #for bs in $BSNODES ; do
    #	cat $OURDIR/fqdn.map | grep -v "^${bs}"$'\t' > $OURDIR/fqdn.map.tmp
    #	mv $OURDIR/fqdn.map.tmp $OURDIR/fqdn.map
    #done
    # XXX: why doesn't the tab grep work here, sigh...
    #cat $OURDIR/fqdn.map | grep -v '^bsnode'$'\t' > $OURDIR/fqdn.map.tmp
    cat $OURDIR/fqdn.map | grep -v '^bsnode' > $OURDIR/fqdn.map.tmp
    mv $OURDIR/fqdn.map.tmp $OURDIR/fqdn.map
    cat $OURDIR/fqdn.map | grep -v '^fw[ \t]*' > $OURDIR/fqdn.map.tmp
    mv $OURDIR/fqdn.map.tmp $OURDIR/fqdn.map
    cat $OURDIR/fqdn.map | grep -v '^fw-s2[ \t]*' > $OURDIR/fqdn.map.tmp
    mv $OURDIR/fqdn.map.tmp $OURDIR/fqdn.map

    cat manifests.xml | tr -d '\n' | sed -e 's/<node /\n<node /g'  | sed -n -e "s/^<node [^>]*component_id=['\"]*[a-zA-Z0-9:\+\.]*node+\([^'\"]*\)['\"].*<host name=['\"]\([^'\"]*\)['\"].*$/\1\t\2/p" > $OURDIR/fqdn.physical.map
    # Add a newline if we wrote anything.
    if [ -s $OURDIR/fqdn.physical.map ]; then
	echo '' >> $OURDIR/fqdn.physical.map
    fi
    # Filter out any blockstore nodes
    cat $OURDIR/fqdn.physical.map | grep -v '[ \t]bsnode\.' > $OURDIR/fqdn.physical.map.tmp
    mv $OURDIR/fqdn.physical.map.tmp $OURDIR/fqdn.physical.map
    # Filter out any firewall nodes
    cat $OURDIR/fqdn.physical.map | grep -v '[ \t]*fw\.' > $OURDIR/fqdn.physical.map.tmp
    mv $OURDIR/fqdn.physical.map.tmp $OURDIR/fqdn.physical.map
    cat $OURDIR/fqdn.physical.map | grep -v '[ \t]*fw-s2\.' > $OURDIR/fqdn.physical.map.tmp
    mv $OURDIR/fqdn.physical.map.tmp $OURDIR/fqdn.physical.map
fi

#
# Setup the fqdn map the non-geni way if necessary!
#
if [ ! -s $OURDIR/fqdn.map ]; then
    TNODES=`cat $TOPOMAP | grep -v '^#' | sed -n -e 's/^\([a-zA-Z0-9\-]*\),.*:.*$/\1/p' | xargs`
    FQDNS=""
    NODES=""
    for n in $TNODES ; do
	# Filter out any blockstore nodes
	grep -q "HOSTID=$n " /var/emulab/boot/tmcc/storageconfig
	if [ $? -eq 0 ] ; then
	    continue
	fi
	# Filter out any firewall nodes
	if [ "$n" = "fw" -o "$n" = "fw-s2" ]; then
	    continue
	fi

	fqdn="$n.$EEID.$EPID.$OURDOMAIN"
	FQDNS="${FQDNS} $fqdn"
	NODES="${NODES} $n"

	/bin/echo -e "$n\t$fqdn" >> $OURDIR/fqdn.map
    done
fi

#
# Grab our list of short-name and FQDN nodes.  One way or the other, we have
# an fqdn map.  First we tried the GENI way; then the old Emulab way with
# topomap.
#
NODES=`cat $OURDIR/fqdn.map | cut -f1 | xargs`
FQDNS=`cat $OURDIR/fqdn.map | cut -f2 | xargs`

if [ -z "${COMPUTENODES}" ]; then
    # Figure out which networkmanager (netmgr) and controller (ctrl) names we have
    for node in $NODES
    do
	if [ "$node" = "networkmanager" ]; then
	    NETWORKMANAGER="networkmanager"
	fi
	if [ "$node" = "controller" ]; then
	    # If we were using the controller as storage and object host, then
	    # keep using it (just use the old name we've detected).
	    if [ "$STORAGEHOST" = "$CONTROLLER" ]; then
		STORAGEHOST="controller"
	    fi
	    if [ "$OBJECTHOST" = "$CONTROLLER" ]; then
		OBJECTHOST="controller"
	    fi
	    CONTROLLER="controller"
	fi
    done
    # Figure out which ones are the compute nodes
    for node in $NODES
    do
	if [ "$node" != "$CONTROLLER" -a "$node" != "$NETWORKMANAGER" \
	     -a "$node" != "$STORAGEHOST" -a "$node" != "$OBJECTHOST" ]; then
	    COMPUTENODES="$COMPUTENODES $node"
	fi
    done
fi

OTHERNODES=""
for node in $NODES
do
    [ "$node" = "$NODEID" ] && continue

    OTHERNODES="$OTHERNODES $node"
done

# Save the node stuff off to settings
grep CONTROLLER $SETTINGS
if [ ! $? = 0 ]; then
    echo "CONTROLLER=\"${CONTROLLER}\"" >> $SETTINGS
    echo "NETWORKMANAGER=\"${NETWORKMANAGER}\"" >> $SETTINGS
    echo "STORAGEHOST=\"${STORAGEHOST}\"" >> $SETTINGS
    echo "OBJECTHOST=\"${OBJECTHOST}\"" >> $SETTINGS
    echo "COMPUTENODES=\"${COMPUTENODES}\"" >> $SETTINGS
elif [ $UPDATING -ne 0 ]; then
    sed -i -e "s/^\(CONTROLLER=\"[^\"]*\"\)\$/CONTROLLER=\"$CONTROLLER\"/" $SETTINGS
    sed -i -e "s/^\(NETWORKMANAGER=\"[^\"]*\"\)\$/NETWORKMANAGER=\"$NETWORKMANAGER\"/" $SETTINGS
    sed -i -e "s/^\(STORAGEHOST=\"[^\"]*\"\)\$/STORAGEHOST=\"$STORAGEHOST\"/" $SETTINGS
    sed -i -e "s/^\(OBJECTHOST=\"[^\"]*\"\)\$/OBJECTHOST=\"$OBJECTHOST\"/" $SETTINGS
    sed -i -e "s/^\(COMPUTENODES=\"[^\"]*\"\)\$/COMPUTENODES=\"$COMPUTENODES\"/" $SETTINGS
fi

#
# 0 (true) if networkmanager node is also the controller; 1 if not.
#
unified() {
    if [ "$NETWORKMANAGER" = "$CONTROLLER" ]; then
	return 0
    else
	return 1
    fi
}

##
## Setup our Ubuntu package mirror, if necessary.
##
grep MIRRORSETUP $SETTINGS
if [ ! $? -eq 0 ]; then
    if [ ! "x${UBUNTUMIRRORHOST}" = "x" ]; then
	oldstr='us.archive.ubuntu.com'
	newstr="${UBUNTUMIRRORHOST}"

	if [ ! "x${UBUNTUMIRRORPATH}" = "x" ]; then
	    oldstr='us.archive.ubuntu.com/ubuntu'
	    newstr="${UBUNTUMIRRORHOST}/${UBUNTUMIRRORPATH}"
	fi

	echo "*** Changing Ubuntu mirror from $oldstr to $newstr ..."
	sed -E -i.us.archive.ubuntu.com -e "s|(${oldstr})|$newstr|" /etc/apt/sources.list
    fi

    echo "MIRRORSETUP=1" >> $SETTINGS
fi

# Setup apt-get to not prompt us
echo "force-confdef" > /etc/dpkg/dpkg.cfg.d/cloudlab
echo "force-confold" >> /etc/dpkg/dpkg.cfg.d/cloudlab
export DEBIAN_FRONTEND=noninteractive
# -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" 
DPKGOPTS=''
APTGETINSTALLOPTS='-y'
APTGETINSTALL="apt-get $DPKGOPTS install $APTGETINSTALLOPTS"
# Don't install/upgrade packages if this is not set
if [ ${DO_APT_INSTALL} -eq 0 ]; then
    APTGETINSTALL="/bin/true ${APTGETINSTALL}"
fi

if [ ! -f $OURDIR/apt-updated -a "${DO_APT_UPDATE}" = "1" ]; then
    #
    # Attempt to handle old EOL releases; so far only need to handle utopic
    #
    . /etc/lsb-release
    grep -q old-releases /etc/apt/sources.list
    if [  $? != 0 -a "x${DISTRIB_CODENAME}" = "xutopic" ]; then
	sed -i -re 's/([a-z]{2}\.)?archive.ubuntu.com|security.ubuntu.com/old-releases.ubuntu.com/g' /etc/apt/sources.list
    fi
    apt-get update
    touch $OURDIR/apt-updated
fi

are_packages_installed() {
    retval=1
    while [ ! -z "$1" ] ; do
	dpkg -s "$1" >/dev/null 2>&1
	if [ ! $? -eq 0 ] ; then
	    retval=0
	fi
	shift
    done
    return $retval
}

maybe_install_packages() {
    if [ ! ${DO_APT_UPGRADE} -eq 0 ] ; then
        # Just do an install/upgrade to make sure the package(s) are installed
	# and upgraded; we want to try to upgrade the package.
	$APTGETINSTALL $@
	return $?
    else
	# Ok, check if the package is installed; if it is, don't install.
	# Otherwise, install (and maybe upgrade, due to dependency side effects).
	# Also, optimize so that we try to install or not install all the
	# packages at once if none are installed.
	are_packages_installed $@
	if [ $? -eq 1 ]; then
	    return 0
	fi

	retval=0
	while [ ! -z "$1" ] ; do
	    are_packages_installed $1
	    if [ $? -eq 0 ]; then
		$APTGETINSTALL $1
		retval=`expr $retval \| $?`
	    fi
	    shift
	done
	return $retval
    fi
}

if [ ! -f $OURDIR/cloudarchive-added -a "${DO_UBUNTU_CLOUDARCHIVE}" = "1" ]; then
    #if [ "${DISTRIB_CODENAME}" = "trusty" ] ; then
    #	$APTGETINSTALL install -y ubuntu-cloud-keyring
    #	echo "deb http://ubuntu-cloud.archive.canonical.com/ubuntu" "${DISTRIB_CODENAME}-updates/${OSCODENAME} main" > /etc/apt/sources.list.d/cloudarchive-${OSCODENAME}.list
    #	apt-get update
    #elif [ "${DISTRIB_CODENAME}" = "xenial" ] ; then
	maybe_install_packages software-properties-common
	# Disable unattended upgrades!
	rm -fv /etc/apt/apt.conf.d/*unattended-upgrades
	add-apt-repository -y cloud-archive:$OSRELEASE
	if [ "${DO_UBUNTU_CLOUDARCHIVE_STAGING}" = "1" ]; then
	    add-apt-repository -y cloud-archive:${OSRELEASE}-proposed
	fi
	apt-get update
    #fi

    touch $OURDIR/cloudarchive-added
fi

if [ ! -f $OURDIR/apt-dist-upgraded -a "${DO_APT_DIST_UPGRADE}" = "1" ]; then
    # First, mark grub packages not to be upgraded; we don't want an
    # install going to the wrong place.
    PKGS="grub-common grub-gfxpayload-lists grub-pc grub-pc-bin grub2-common"
    for pkg in $PKGS; do
	apt-mark hold $pkg
    done
    apt-get dist-upgrade -y
    for pkg in $PKGS; do
	apt-mark unhold $pkg
    done
    touch $OURDIR/apt-dist-upgraded
fi

#
# We rely on crudini in a few spots, instead of sed whacking.
#
maybe_install_packages crudini

netmask2prefix() {
    nm=$1
    bits=0
    IFS=.
    read -r i1 i2 i3 i4 <<EOF
$nm
EOF
    unset IFS
    for n in $i1 $i2 $i3 $i4 ; do
	v=128
	while [ $v -gt 0 ]; do
	    bits=`expr $bits + \( \( $n / $v \) % 2 \)`
	    v=`expr $v / 2`
	done
    done
    echo $bits
}

#
# Create IP addresses for the Management and Data networks, as necessary.
#
if [ ! -f $OURDIR/nextsparesubnet ] ; then
    #
    # This is horrible, but for openstack networks that need IP addrs, that
    # were not specified in our experiment description (i.e., by Emulab,
    # Cloudlab, or the geni-lib based rspec file), we have to generate them.
    # We stay away from 172.16 because Emulab/Cloudlab use it internally for
    # virtual machine IP addresses.  We also know that Emulab/Cloudlab/geni-lib
    # always allocate addresses starting at 10.1.1.1, and increment the second
    # octet for a new subnet.  We assume that 1) no subnet will ever be larger
    # than 255*255 hosts, and 2) that we can start our subnets at 10.254.0.0
    # and decrement the second octet any time we need to IP a new openstack
    # network.
    #
    NEXTSPARESUBNET=254
    echo ${NEXTSPARESUBNET} > $OURDIR/nextsparesubnet
else
    NEXTSPARESUBNET=`cat $OURDIR/nextsparesubnet`
fi

if [ ! -f $OURDIR/mgmt-hosts -o $UPDATING -ne 0 ] ; then
    echo "*** Setting up Management and Data Network IP Addresses"

    if [ -z "${MGMTLAN}" -o ${USE_EXISTING_IPS} -eq 0 ]; then
	if [ $UPDATING -eq 0 ]; then
	    echo "255.255.0.0" > $OURDIR/mgmt-netmask
	    echo "192.168.0.1 $NETWORKMANAGER" > $OURDIR/mgmt-hosts
	    if ! unified ; then
		echo "192.168.0.3 $CONTROLLER" >> $OURDIR/mgmt-hosts
	    fi
	    o3=0
	    o4=5
	else
	    o3=`cat $OURDIR/mgmt-o3`
	    o4=`cat $OURDIR/mgmt-o4`
	fi

	for node in $NODES
	do
	    [ "$node" = "$CONTROLLER" -o "$node" = "$NETWORKMANAGER" ] \
		&& continue

	    # If it already exists, skip it.
	    grep -q ${node}\$ $OURDIR/mgmt-hosts
	    if [ $? -eq 0 ]; then
		continue
	    fi

	    echo "192.168.$o3.$o4 $node" >> $OURDIR/mgmt-hosts

            # Skip 2 for openvpn tun tunnels
	    o4=`expr $o4 + 2`
	    if [ $o4 -gt 253 ] ; then
		o4=10
		o3=`expr $o3 + 1`
	    fi
	done

	# Save off our octets for later
	echo "$o3" > $OURDIR/mgmt-o3
	echo "$o4" > $OURDIR/mgmt-o4
    else
	cat $TOPOMAP | grep -v '^#' | sed -e 's/,/ /' \
	    | sed -n -e "s/\([a-zA-Z0-9_\-]*\) .*${MGMTLAN}:\([0-9\.]*\).*\$/\2\t\1/p" \
	    > $OURDIR/mgmt-hosts
	cat ${BOOTDIR}/tmcc/ifconfig \
	    | sed -n -e "s/^.* MASK=\([0-9\.]*\) .* LAN=${MGMTLAN}.*$/\1/p" \
	    > $OURDIR/mgmt-netmask
    fi

    #
    # If USE_EXISTING_IPS is set to 0, we will re-IP those data lan
    # interfaces: networkmanager:eth1 gets 10.z.0.1/8, and controller gets
    # 10.z.0.3/8; and the compute nodes get 10.z.x.y, where x starts at 1,
    # and y starts at 1 and does not exceed 254.
    #
    # We only assign IPs to flat networks because they are the only networks
    # that the physical hosts (i.e., controller, networkmanager, compute nodes)
    # have an interface on.  Technically, we don't *need* to do this, but do it.
    # One thing it gives us is the ability to run GRE or VXLAN networks over the
    # flat networks.
    #
    if [ ${USE_EXISTING_IPS} -eq 0 ]; then
	for lan in $DATAFLATLANS $DATAVLANS $DATAOTHERLANS ; do
	    if [ $UPDATING -eq 0 ]; then
		prefix="10.$NEXTSPARESUBNET"
		echo "$prefix" > $OURDIR/data-prefix.$lan
		echo "255.255.0.0" > $OURDIR/data-netmask.$lan
		echo "$prefix.0.0/16" > $OURDIR/data-cidr.$lan
		echo "$prefix.0.0" > $OURDIR/data-network.$lan
		echo "$prefix.0.1 $NETWORKMANAGER" > $OURDIR/data-hosts.$lan
		if ! unified ; then
		    echo "$prefix.0.3 $CONTROLLER" >> $OURDIR/data-hosts.$lan
		fi

                #
                # Now set static IPs for the compute nodes.
                #
		o3=1
		o4=1
	    else
		prefix=`cat $OURDIR/data-prefix.$lan`
		o3=`cat $OURDIR/data-o3.$lan`
		o4=`cat $OURDIR/data-o4.$lan`
	    fi

	    for node in $NODES
	    do
		[ "$node" = "$CONTROLLER" -o "$node" = "$NETWORKMANAGER" ] \
		    && continue

                # If it already exists, skip it.
		grep -q ${node}\$ $OURDIR/data-hosts.$lan
		if [ $? -eq 0 ]; then
		    continue
		fi

		echo "$prefix.$o3.$o4 $node" >> $OURDIR/data-hosts

                # Skip 2 for openvpn tun tunnels
		o4=`expr $o4 + 1`
		if [ $o4 -gt 254 ] ; then
		    o4=10
		    o3=`expr $o3 + 1`
		fi
	    done

	    if [ $o3 -gt 128 ]; then
		echo "ERROR: more physical hosts than $prefix.$o3 ; aborting!"
		exit 1
	    fi

	    # Save off our octets for later
	    echo $o3 > $OURDIR/data-o3.$lan
	    echo $o4 > $OURDIR/data-o4.$lan

	    if [ $UPDATING -eq 0 ]; then
	        # Start the pool at the next availble addr!  Don't skip.
	        # XXX: could cause problems for adding new phys hosts... oh well.
		o3=`expr $o3 + 10`
		if [ $SUPPORT_DYNAMIC_NODES -eq 1 ]; then
		    # Well, ok, so, let's just start at 128.  Why?  That
		    # leaves us room for 128*255-N physical hosts, plus
		    # 128*255 virtual machines at any time (and
		    # openstack will reuse ip addrs I'm sure).  So we
		    # have a long time before phys node wraparound...
		    echo "*** Changing from calculated o3=$o3/o4=$o4 to o3=128/o4=$o4 to support dynamic nodes..."
		    o3=128
		fi
	        # Also save two addrs, one for the dhcp agent, and one for the
	        # router interface
		echo "start=$prefix.$o3.3,end=10.$NEXTSPARESUBNET.254.254" \
		    > $OURDIR/data-allocation-pool.$lan

		echo "$prefix.$o3.1" > $OURDIR/router-ipaddr.$lan
		echo "$prefix.$o3.2" > $OURDIR/dhcp-agent-ipaddr.$lan

		NEXTSPARESUBNET=`expr $NEXTSPARESUBNET + 1`
	    fi
	done
    else
	for lan in $DATAFLATLANS $DATAOTHERLANS ; do
	    cat $TOPOMAP | grep -v '^#' | sed -e 's/,/ /' \
		| sed -n -e "s/\([a-zA-Z0-9_\-]*\) .*${lan}:\([0-9\.]*\).*\$/\2\t\1/p" \
		> $OURDIR/data-hosts.$lan
	    netmask=`cat ${BOOTDIR}/tmcc/ifconfig \
  		         | sed -n -e "s/^.* MASK=\([0-9\.]*\) .* LAN=${lan}.*$/\1/p"`
	    echo "$netmask" > $OURDIR/data-netmask.$lan
	    nmdataip=`cat $OURDIR/data-hosts.${lan} | grep ${NETWORKMANAGER} | sed -n -e 's/^\([0-9]*.[0-9]*.[0-9]*.[0-9]*\).*$/\1/p'`
	    IFS=.
	    read -r i1 i2 i3 i4 <<EOF
$nmdataip
EOF
	    read -r m1 m2 m3 m4 <<EOF
$netmask
EOF
	    unset IFS
	    network=`printf "%d.%d.%d.%d\n" "$((i1 & m1))" "$((i2 & m2))" "$((i3 & m3))" "$((i4 & m4))"`
	    cidr=`python $DIRNAME/ipcalc.py mask2bits $netmask`
	    echo "$network/$cidr" > $OURDIR/data-cidr.$lan
	    echo "$network" > $OURDIR/data-network.$lan

	    if [ $UPDATING -eq 0 ]; then
	        #
	        # Setup our allocation pool
	        #
	        # First grab all our IP addresses
		allips=`cat $OURDIR/data-hosts.$lan | sed -n -e 's/^\([0-9]*.[0-9]*.[0-9]*.[0-9]*\).*$/\1/p'`
		gi1=0; gi2=0; gi3=0; gi4=0;
	        # Figure out the max currently-used IP in this subnet
		for ip in ${allips} ; do
		    IFS=.
		    read -r i1 i2 i3 i4 <<EOF
$ip
EOF
		    unset IFS
		    if [ $i1 -gt $gi1 ]; then gi1=$i1; gi2=0;gi3=0;gi4=0; fi
		    if [ $i2 -gt $gi2 ]; then gi2=$i2; gi3=0;gi4=0; fi
		    if [ $i3 -gt $gi3 ]; then gi3=$i3; gi4=0; fi
		    if [ $i4 -gt $gi4 ]; then gi4=$i4; fi
		done
	        # Get the next available one...
	        # Note, we don't try to stay inside the netmask :(
		gi4=`expr $gi4 + 1`
		if [ $gi4 = 255 ]; then gi4=1; gi3=`expr $gi3 + 1`; fi
		if [ $gi3 = 255 ]; then gi3=1; gi2=`expr $gi2 + 1`; fi
		if [ $gi2 = 255 ]; then gi2=1; gi1=`expr $gi1 + 1`; fi

		endaddr=`printf "%d.%d.%d.%d\n" "$((i1 | ((~m1)+256)))" "$((i2 | ((~m2)+256)))" "$((i3 | ((~m3)+256)))" "$((i4 | ((~m4)+256)))"`

	        #
                # So, this previous calculation is correct, but openstack doesn't
	        # like 255 in any of the octets!  Argh!  So, "fix" any that have it.
                # Argh...
                #
		IFS=.
		read -r i1 i2 i3 i4 <<EOF
$endaddr
EOF
		unset IFS
		if [ $i1 = 255 ]; then i1=254; fi
		if [ $i2 = 255 ]; then i2=254; fi
		if [ $i3 = 255 ]; then i3=254; fi
		if [ $i4 = 255 ]; then i4=254; fi
		endaddr="$i1.$i2.$i3.$i4"

	        # Also save two addrs, one for the dhcp agent, and one for the
	        # router interface
		echo "$gi1.$gi2.$gi3.$gi4" > $OURDIR/router-ipaddr.$lan
		gi4=`expr $gi4 + 1`
		echo "$gi1.$gi2.$gi3.$gi4" > $OURDIR/dhcp-agent-ipaddr.$lan
		gi4=`expr $gi4 + 1`
	        # Start the pool at the next availble addr!  Don't skip.
	        # XXX: could cause problems for adding new phys hosts... oh well.
		if [ $SUPPORT_DYNAMIC_NODES -eq 1 ]; then
		    # Well, ok, so, let's just start at 128.  Why?  That
		    # leaves us room for 128*255-N physical hosts, plus
		    # 128*255 virtual machines at any time (and
		    # openstack will reuse ip addrs I'm sure).  So we
		    # have a long time before phys node wraparound...
		    echo "*** Changing from gi3=$gi3/gi4=$gi4 to gi3=128/gi4=1 to support dynamic nodes..."
		    gi3=128
		    gi4=1
		fi
		# Write the allocation pool.
		echo "start=$gi1.$gi2.$gi3.$gi4,end=$endaddr" \
		    > $OURDIR/data-allocation-pool.$lan
	    fi
	done
    fi

    # Save off nextsparesubnet
    echo "${NEXTSPARESUBNET}" > $OURDIR/nextsparesubnet
fi

#
# Setup IP configuration for neutron tunnel nets
#
if [ ${DATATUNNELS} -gt 0 ]; then
    i=0
    while [ $i -lt ${DATATUNNELS} ]; do
	if [ -f "$OURDIR/ipinfo.tun${i}" ]; then
	    i=`expr $i + 1`
	    continue
	fi

	LAN="tun${i}"
	subnet=${NEXTSPARESUBNET}

	echo "LAN='$LAN'" >> $OURDIR/ipinfo.$LAN
	echo "ALLOCATION_POOL='start=10.${subnet}.1.1,end=10.${subnet}.254.254'" >> $OURDIR/ipinfo.$LAN
	echo "CIDR='10.$subnet.0.0/16'" >> $OURDIR/ipinfo.$LAN

	NEXTSPARESUBNET=`expr ${NEXTSPARESUBNET} - 1`
	i=`expr $i + 1`
    done

    # Save off nextsparesubnet
    echo "${NEXTSPARESUBNET}" > $OURDIR/nextsparesubnet
fi

#
# Setup IP configuration for vlan networks
#
for lan in $DATAVLANS ; do
    if [ -f $OURDIR/ipinfo.$lan ]; then
	continue
    fi

    LAN="$lan"
    subnet=${NEXTSPARESUBNET}

    echo "LAN='$LAN'" >> $OURDIR/ipinfo.$LAN
    echo "ALLOCATION_POOL='start=10.${subnet}.1.1,end=10.${subnet}.254.254'" >> $OURDIR/ipinfo.$LAN
    echo "CIDR='10.$subnet.0.0/16'" >> $OURDIR/ipinfo.$LAN

    NEXTSPARESUBNET=`expr ${NEXTSPARESUBNET} - 1`
done
# Save off nextsparesubnet
echo "${NEXTSPARESUBNET}" > $OURDIR/nextsparesubnet

#
# Setup IP configuration for neutron vxlan nets
#
if [ ${DATAVXLANS} -gt 0 ]; then
    i=0
    while [ $i -lt ${DATAVXLANS} ]; do
	if [ -f "$OURDIR/ipinfo.vxlan${i}" ]; then
	    i=`expr $i + 1`
	    continue
	fi

	LAN="vxlan${i}"
	subnet=${NEXTSPARESUBNET}

	echo "LAN='$LAN'" >> $OURDIR/ipinfo.$LAN
	echo "ALLOCATION_POOL='start=10.${subnet}.1.1,end=10.${subnet}.254.254'" >> $OURDIR/ipinfo.$LAN
	echo "CIDR='10.$subnet.0.0/16'" >> $OURDIR/ipinfo.$LAN

	NEXTSPARESUBNET=`expr ${NEXTSPARESUBNET} - 1`
	i=`expr $i + 1`
    done

    # Save off nextsparesubnet
    echo "${NEXTSPARESUBNET}" > $OURDIR/nextsparesubnet
fi

#
# NB: this IP/mask is only valid after setting up the management network IP
# addresses because they might not be the Emulab ones.
#
if [ ! -e $OURDIR/info.mgmt ]; then
    MGMTIP=`grep -E "$NODEID$" $OURDIR/mgmt-hosts | head -1 | sed -n -e 's/^\\([0-9]*\\.[0-9]*\\.[0-9]*\\.[0-9]*\\).*$/\\1/p'`
    MGMTNETMASK=`cat $OURDIR/mgmt-netmask`
    MGMTPREFIX=`netmask2prefix $MGMTNETMASK`
    if [ -z "$MGMTLAN" ] ; then
	MGMTVLAN=0
	MVMTVLANDEV=
	MGMTMAC=""
	MGMT_NETWORK_INTERFACE="tun0"
    else
	cat ${BOOTDIR}/tmcc/ifconfig | grep "IFACETYPE=vlan" | grep "${MGMTLAN}"
	if [ $? = 0 ]; then
	    MGMTVLAN=1
	    MGMTMAC=`cat ${BOOTDIR}/tmcc/ifconfig | sed -n -e "s/^.* VMAC=\([0-9a-f:\.]*\) .* LAN=${MGMTLAN}.*\$/\1/p"`
	    MGMT_NETWORK_INTERFACE=`/usr/local/etc/emulab/findif -m $MGMTMAC`
	    MGMTVLANDEV=`ip link show ${MGMT_NETWORK_INTERFACE} | sed -n -e "s/^.*${MGMT_NETWORK_INTERFACE}\@\([0-9a-zA-Z_]*\): .*\$/\1/p"`
	else
	    MGMTVLAN=0
	    MGMTMAC=`cat ${BOOTDIR}/tmcc/ifconfig | sed -n -e "s/.* MAC=\([0-9a-f:\.]*\) .* LAN=${MGMTLAN}/\1/p"`
	    MGMT_NETWORK_INTERFACE=`/usr/local/etc/emulab/findif -m $MGMTMAC`
	    MGMTVLANDEV=
	fi
    fi
    echo "MGMTIP='$MGMTIP'" >> $OURDIR/info.mgmt
    echo "MGMTNETMASK='$MGMTNETMASK'" >> $OURDIR/info.mgmt
    echo "MGMTPREFIX='$MGMTPREFIX'" >> $OURDIR/info.mgmt
    echo "MGMTVLAN=$MGMTVLAN" >> $OURDIR/info.mgmt
    echo "MGMTMAC='$MGMTMAC'" >> $OURDIR/info.mgmt
    echo "MGMT_NETWORK_INTERFACE='$MGMT_NETWORK_INTERFACE'" >> $OURDIR/info.mgmt
    echo "MGMTVLANDEV='$MGMTVLANDEV'" >> $OURDIR/info.mgmt
else
    . $OURDIR/info.mgmt
fi

#
# NB: this IP/mask is only valid after data ips have been assigned, because
# they might not be the Emulab ones.
#
for lan in $DATAFLATLANS $DATAOTHERLANS ; do
    if [ -e $OURDIR/info.$lan ] ; then
	continue
    fi

    DATAIP=`cat $OURDIR/data-hosts.$lan | grep -E "$NODEID$" | sed -n -e 's/^\([0-9]*.[0-9]*.[0-9]*.[0-9]*\).*$/\1/p'`
    DATANETMASK=`cat $OURDIR/data-netmask.$lan`
    cat ${BOOTDIR}/tmcc/ifconfig | grep "IFACETYPE=vlan" | grep "${lan}"
    if [ $? = 0 ]; then
	DATAVLAN=1
	DATAMAC=`cat ${BOOTDIR}/tmcc/ifconfig | sed -n -e "s/^.* VMAC=\([0-9a-f:\.]*\) .* LAN=${lan}.*\$/\1/p"`
	DATADEV=`/usr/local/etc/emulab/findif -m $DATAMAC`
	DATAVLANDEV=`ip link show ${DATADEV} | sed -n -e "s/^.*${DATADEV}\@\([0-9a-zA-Z_]*\): .*\$/\1/p"`
	DATAVLANTAG=`cat ${BOOTDIR}/tmcc/ifconfig | sed -n -e "s/^.* LAN=${lan} VTAG=\([0-9]*\).*\$/\1/p"`
	DATAPMAC=`cat ${BOOTDIR}/tmcc/ifconfig | sed -n -e "s/^.* PMAC=\([0-9a-f:\.]*\) .* LAN=${lan}.*\$/\1/p"`
    else
	DATAVLAN=0
	DATAVLANDEV=""
	DATAVLANTAG=0
	DATAMAC=`cat ${BOOTDIR}/tmcc/ifconfig | sed -n -e "s/^.* MAC=\([0-9a-f:\.]*\) .* LAN=${lan}.*$/\1/p"`
	DATADEV=`/usr/local/etc/emulab/findif -m $DATAMAC`
	DATAPMAC=
    fi

    echo "DATABRIDGE=br-${lan}" >> $OURDIR/info.$lan
    echo "DATAIP=${DATAIP}" >> $OURDIR/info.$lan
    echo "DATANETMASK=${DATANETMASK}" >> $OURDIR/info.$lan
    echo "DATAVLAN=${DATAVLAN}" >> $OURDIR/info.$lan
    echo "DATAVLANTAG=${DATAVLANTAG}" >> $OURDIR/info.$lan
    echo "DATAVLANDEV=${DATAVLANDEV}" >> $OURDIR/info.$lan
    echo "DATAMAC=${DATAMAC}" >> $OURDIR/info.$lan
    echo "DATAPMAC=${DATAPMAC}" >> $OURDIR/info.$lan
    echo "DATADEV=${DATADEV}" >> $OURDIR/info.$lan
done

for lan in $DATAVLANS ; do
    if [ -e $OURDIR/info.$lan ] ; then
	continue
    fi

    #DATAIP=`cat $OURDIR/data-hosts.$lan | grep -E "$NODEID$" | sed -n -e 's/^\([0-9]*.[0-9]*.[0-9]*.[0-9]*\).*$/\1/p'`
    #DATANETMASK=`cat $OURDIR/data-netmask.$lan`
    DATAVLAN=1
    DATAMAC=`cat ${BOOTDIR}/tmcc/ifconfig | sed -n -e "s/^.* VMAC=\([0-9a-f:\.]*\) .* LAN=${lan}.*\$/\1/p"`
    DATADEV=`/usr/local/etc/emulab/findif -m $DATAMAC`
    DATAVLANDEV=`ip link show ${DATADEV} | sed -n -e "s/^.*${DATADEV}\@\([0-9a-zA-Z_]*\): .*\$/\1/p"`
    DATAVLANTAG=`cat ${BOOTDIR}/tmcc/ifconfig | sed -n -e "s/^.* LAN=${lan} VTAG=\([0-9]*\).*\$/\1/p"`

    echo "DATABRIDGE=br-${DATAVLANDEV}" >> $OURDIR/info.$lan
    #echo "DATAIP=${DATAIP}" >> $OURDIR/info.$lan
    #echo "DATANETMASK=${DATANETMASK}" >> $OURDIR/info.$lan
    echo "DATAVLAN=${DATAVLAN}" >> $OURDIR/info.$lan
    echo "DATAVLANTAG=${DATAVLANTAG}" >> $OURDIR/info.$lan
    echo "DATAVLANDEV=${DATAVLANDEV}" >> $OURDIR/info.$lan
    echo "DATAMAC=${DATAMAC}" >> $OURDIR/info.$lan
    echo "DATADEV=${DATADEV}" >> $OURDIR/info.$lan
done

##
## Setup some one-time neutron configuration variables, based on our network
## configuration
##
if [ ! -f $OURDIR/neutron.vars ]; then
    #
    # Which type drives do we want to configure?
    #
    network_types=""
    # NB: we always configure flat, because the external net is flat
    #if [ -n "${DATAFLATLANS}" ]; then
	if [ -n "${network_types}" ]; then
	    network_types="${network_types},"
	fi
	network_types="${network_types}flat"
    #fi
    if [ -n "${DATAFLATLANS}" -a ${DATATUNNELS} -gt 0 ]; then
	if [ -n "${network_types}" ]; then
	    network_types="${network_types},"
	fi
	network_types="${network_types}gre"
    fi
    if [ -n "${DATAVLANS}" ]; then
	if [ -n "${network_types}" ]; then
	    network_types="${network_types},"
	fi
	network_types="${network_types}vlan"
    fi
    if [ -n "${DATAVXLANS}" ]; then
	if [ -n "${network_types}" ]; then
	    network_types="${network_types},"
	fi
	network_types="${network_types}vxlan"
    fi

    echo "network_types=\"${network_types}\"" >> $OURDIR/neutron.vars

    #
    # What are our flat networks?
    #
    flat_networks="external"
    for lan in $DATAFLATLANS ; do
	if [ -n "${flat_networks}" ]; then
	    flat_networks="${flat_networks},"
	fi
	flat_networks="${flat_networks}${lan}"
    done

    echo "flat_networks=\"${flat_networks}\"" >> $OURDIR/neutron.vars

    #
    # Figure out the bridge mappings
    #
    # NB: We can only control the name of the external br-ex bridge,
    # because only the Neutron linuxbridge driver accepts both a map of
    # physical networks to physical interfaces; and physical network to
    # bridge names.  Nova assumes that the bridge it must plug a device
    # into is named according to the physical network uuid.  Thus, for
    # the linuxbridge case, we only setup bridge_mappings for
    # br-ex... modulo a flag.  Hopefully in the future they will see the
    # sense in allowing static bridge configurations.
    #
    bridge_mappings="bridge_mappings=external:br-ex"
    extra_mappings=""
    if [ "${ML2PLUGIN}" = "linuxbridge" ]; then
	extra_mappings="physical_interface_mappings=external:${EXTERNAL_NETWORK_INTERFACE}"
    fi
    for lan in $DATAFLATLANS ; do
	. $OURDIR/info.${lan}
	if [ "${ML2PLUGIN}" = "linuxbridge" ]; then
	    extra_mappings="${extra_mappings},${lan}:${DATADEV}"
	    if [ $LINUXBRIDGE_STATIC -eq 1 ]; then
		bridge_mappings="${bridge_mappings},${lan}:${DATABRIDGE}"
	    fi
	else
	    bridge_mappings="${bridge_mappings},${lan}:${DATABRIDGE}"
	fi
    done
    for lan in $DATAVLANS ; do
	. $OURDIR/info.${lan}
	# NB: neutron doesn't like to see the same map entry multiple times...
	echo "$bridge_mappings" | grep -q "${DATAVLANDEV}:"
	if [ $? = 0 ] ; then
	    continue;
	else
	    if [ "${ML2PLUGIN}" = "linuxbridge" ]; then
		extra_mappings="${extra_mappings},${lan}:${DATADEV}"
		if [ $LINUXBRIDGE_STATIC -eq 1 ]; then
		    bridge_mappings="${bridge_mappings},${DATAVLANDEV}:${DATABRIDGE}"
		fi
	    else
		bridge_mappings="${bridge_mappings},${DATAVLANDEV}:${DATABRIDGE}"
	    fi
	fi
    done

    echo "bridge_mappings=\"${bridge_mappings}\"" >> $OURDIR/neutron.vars
    echo "extra_mappings=\"${extra_mappings}\"" >> $OURDIR/neutron.vars

    #
    # Figure out the network_vlan_ranges
    #
    network_vlan_ranges=""
    for lan in $DATAVLANS ; do
	. $OURDIR/info.${lan}
	if [ -n "${network_vlan_ranges}" ] ; then
	    network_vlan_ranges="${network_vlan_ranges},"
	fi
	network_vlan_ranges="${network_vlan_ranges}${DATAVLANDEV}:${DATAVLANTAG}:${DATAVLANTAG}"
    done

    echo "network_vlan_ranges=\"network_vlan_ranges=${network_vlan_ranges}\"" >> $OURDIR/neutron.vars

    #
    # What's our first flat network, which will host our GRE tunnels?
    #
    gre_local_ip=""
    enable_tunneling=""
    tunnel_types=""
    for lan in $DATAFLATLANS ; do
	. $OURDIR/info.$lan

        # Just use the first one
	gre_local_ip="local_ip = $DATAIP"
	enable_tunneling="enable_tunneling = True"
	tunnel_types=""
	if [ ${DATATUNNELS} -gt 0 ]; then
	    if [ -z "${tunnel_types}" ]; then
		tunnel_types="tunnel_types = gre"
	    else
		tunnel_types="${tunnel_types},gre"
	    fi
	fi
	if [ ${DATAVXLANS} -gt 0 ]; then
	    if [ -z "${tunnel_types}" ]; then
		tunnel_types="tunnel_types = vxlan"
	    else
		tunnel_types="${tunnel_types},vxlan"
	    fi
	fi

	break
    done

    echo "gre_local_ip=\"${gre_local_ip}\"" >> $OURDIR/neutron.vars
    echo "enable_tunneling=\"${enable_tunneling}\"" >> $OURDIR/neutron.vars
    echo "tunnel_types=\"${tunnel_types}\"" >> $OURDIR/neutron.vars

    if [ "${ML2PLUGIN}" = "openvswitch" ]; then
	interface_driver='neutron.agent.linux.interface.OVSInterfaceDriver'
    else
	interface_driver='neutron.agent.linux.interface.BridgeInterfaceDriver'
    fi

    echo "interface_driver=\"${interface_driver}\"" >> $OURDIR/neutron.vars
    
    fwdriver=""
    if [ "${ML2PLUGIN}" = "openvswitch" ]; then
	fwdriver="neutron.agent.linux.iptables_firewall.OVSHybridIptablesFirewallDriver"
    else
	fwdriver="neutron.agent.linux.iptables_firewall.IptablesFirewallDriver"
    fi
    if [ ${DISABLE_SECURITY_GROUPS} -eq 1 ]; then
	fwdriver="neutron.agent.firewall.NoopFirewallDriver"
    fi

    echo "fwdriver=\"${fwdriver}\"" >> $OURDIR/neutron.vars

fi

#
# Emulab tmcc finds the bossip via first server in /etc/resolv.conf,
# ugh, and we might change /etc/resolv.conf if we are installing
# Designate on >= Ocata.  So force it to find the bossip via this file
# instead.  Previously, we had done this near the bottom of
# setup-controller.sh, but this change has to be made in a
# multi-cluster-compatible manner; the bossip could be different for
# phys node at different clusters.
#
if [ ! -f /etc/emulab/bossnode -a $OSVERSION -ge $OSNEWTON -a "${USE_DESIGNATE_AS_RESOLVER}" = "1" ]; then
    mydomain=`hostname | sed -n -e 's/[^\.]*\.\(.*\)$/\1/p'`
    mynameserver=`sed -n -e 's/^nameserver \([0-9]*\.[0-9]*\.[0-9]*\.[0-9]*\).*$/\1/p' < /etc/resolv.conf | head -1`
    if [ -z "$mynameserver" ]; then
	mynameserver=`dig +short boss.$mydomain A`
    fi
    if [ -n "$mynameserver" ]; then
	echo $mynameserver > /etc/emulab/bossnode
    fi
fi

##
## Finally, if we had been UPDATING, remove the lockfile!
##
if [ $UPDATING -ne 0 ]; then
    $RMLOCKFILE $OURDIR/UPDATING
fi

##
## Util functions.
##

getfqdn() {
    n=$1
    fqdn=`cat $OURDIR/fqdn.map | grep -E "$n\s" | cut -f2`
    echo $fqdn
}

service_enable() {
    service=$1
    if [ ${HAVE_SYSTEMD} -eq 0 ]; then
	update-rc.d $service enable
    else
	systemctl enable $service
    fi
}

service_disable() {
    service=$1
    if [ ${HAVE_SYSTEMD} -eq 0 ]; then
	update-rc.d $service disable
    else
	systemctl disable $service
    fi
}

service_restart() {
    service=$1
    if [ ${HAVE_SYSTEMD} -eq 0 ]; then
	service $service restart
    else
	systemctl restart $service
    fi
}

service_stop() {
    service=$1
    if [ ${HAVE_SYSTEMD} -eq 0 ]; then
	service $service stop
    else
	systemctl stop $service
    fi
}

service_start() {
    service=$1
    if [ ${HAVE_SYSTEMD} -eq 0 ]; then
	service $service start
    else
	systemctl start $service
    fi
}

GETTER=`which wget`
if [ -n "$GETTER" ]; then
    GETTEROUT="$GETTER --remote-encoding=unix -c -O"
    GETTER="$GETTER --remote-encoding=unix -c -N"
    GETTERLOGARG="-o"
else
    GETTER="/bin/false NO WGET INSTALLED!"
    GETTEROUT="/bin/false NO WGET INSTALLED!"
fi

get_url() {
    if [ -z "$GETTER" ]; then
	/bin/false
	return
    fi

    urls="$1"
    outfile="$2"
    if [ -n "$3" ]; then
	retries=$3
    else
	retries=3
    fi
    if [ -n "$4" ]; then
	interval=$4
    else
	interval=5
    fi
    if [ -n "$5" ]; then
	force="$5"
    else
	force=0
    fi

    if [ -n "$outfile" -a -f "$outfile" -a $force -ne 0 ]; then
	rm -f "$outfile"
    fi

    success=0
    tmpfile=`mktemp /tmp/wget.log.XXX`
    for url in $urls ; do
	tries=$retries
	while [ $tries -gt 0 ]; do
	    if [ -n "$outfile" ]; then
		$GETTEROUT $outfile $GETTERLOGARG $tmpfile "$url"
	    else
		$GETTER $GETTERLOGARG $tmpfile "$url"
	    fi
	    if [ $? -eq 0 ]; then
		if [ -z "$outfile" ]; then
		    # This is the best way to figure out where wget
		    # saved a file!
		    outfile=`bash -c "cat $tmpfile | sed -n -e 's/^.*Saving to: '$'\u2018''\([^'$'\u2019'']*\)'$'\u2019''.*$/\1/p'"`
		    if [ -z "$outfile" ]; then
			outfile=`bash -c "cat $tmpfile | sed -n -e 's/^.*File '$'\u2018''\([^'$'\u2019'']*\)'$'\u2019'' not modified.*$/\1/p'"`
		    fi
		fi
		success=1
		break
	    else
		sleep $interval
		tries=`expr $tries - 1`
	    fi
	done
	if [ $success -eq 1 ]; then
	    break
	fi
    done

    rm -f $tmpfile

    if [ $success -eq 1 ]; then
	echo "$outfile"
	/bin/true
    else
	/bin/false
    fi
}

# Time logging
if [ $FIRSTTIME -ne 0 ]; then
    logtend "libfirsttime"
fi
