#!/bin/sh

##
## Initialize some basic useful stuff.
##

set -x

DIRNAME=`dirname $0`

# Gotta know the rules!
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Grab our libs
. "$DIRNAME/setup-lib.sh"

if [ "$HOSTNAME" != "$CONTROLLER" ]; then
    exit 0;
fi

logtstart "basic-users"

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi

. $OURDIR/admin-openrc.sh

if [ $GENIUSER -eq 1 ] ; then
    echo "*** Importing GENI user keys for admin user..."
    $DIRNAME/setup-user-info.py

    #
    # XXX: ugh, this is ugly, but now that we have two admin users, we have
    # to create keys for the admin user -- but we upload keys as the adminapi
    # user.  I can't find a way with the API to upload keys for another user
    # (seems very dumb, I must be missing something, but...)... so what we do
    # is add the keys once for the adminapi user, change the db manually to
    # make those keys be for the admin user, then add the same keys again (for
    # the adminapi user).  Then both admin users have the keys.
    #
    if [ -x /usr/bin/keystone ]; then
	AAID=`keystone user-get ${ADMIN_API} | awk '/ id / {print $4}'`
	AID=`keystone user-get admin | awk '/ id / {print $4}'`
    else
	AAID=`openstack user show adminapi | awk '/ id / { print $4 }'`
	AID=`openstack user show admin | awk '/ id / { print $4 }'`
    fi
    echo "update key_pairs set user_id='$AID' where user_id='$AAID'" \
	| mysql -u root --password=${DB_ROOT_PASS} nova

    # Ok, do it again!
    echo "*** Importing GENI user keys, for ${ADMIN_API} user..."
    $DIRNAME/setup-user-info.py
fi

logtend "basic-users"

exit 0
