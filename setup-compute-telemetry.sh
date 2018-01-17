#!/bin/sh

##
## Setup a OpenStack compute node for Ceilometer.
##

set -x

# Gotta know the rules!
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Grab our libs
. "`dirname $0`/setup-lib.sh"

if [ "$HOSTNAME" = "$CONTROLLER" -o "$HOSTNAME" = "$NETWORKMANAGER" ]; then
    exit 0;
fi

if [ -f $OURDIR/setup-compute-telemetry-done ]; then
    exit 0
fi

logtstart "compute-telemetry"

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi

if [ $OSVERSION -ge $OSMITAKA ]; then
    PROJECT_DOMAIN_PARAM="project_domain_name"
    USER_DOMAIN_PARAM="user_domain_name"
else
    PROJECT_DOMAIN_PARAM="project_domain_id"
    USER_DOMAIN_PARAM="user_domain_id"
fi
if [ $OSVERSION -ge $OSMITAKA ]; then
    AUTH_TYPE_PARAM="auth_type"
else
    AUTH_TYPE_PARAM="auth_plugin"
fi

maybe_install_packages ceilometer-agent-compute

crudini --set /etc/ceilometer/ceilometer.conf DEFAULT auth_strategy keystone
crudini --set /etc/ceilometer/ceilometer.conf glance host $CONTROLLER
crudini --set /etc/ceilometer/ceilometer.conf DEFAULT verbose $VERBOSE_LOGGING
crudini --set /etc/ceilometer/ceilometer.conf DEFAULT debug $DEBUG_LOGGING
crudini --set /etc/ceilometer/ceilometer.conf DEFAULT \
    log_dir /var/log/ceilometer

if [ $OSVERSION -lt $OSKILO ]; then
    crudini --set /etc/ceilometer/ceilometer.conf DEFAULT rpc_backend rabbit
    crudini --set /etc/ceilometer/ceilometer.conf DEFAULT rabbit_host $CONTROLLER
    crudini --set /etc/ceilometer/ceilometer.conf DEFAULT rabbit_userid ${RABBIT_USER}
    crudini --set /etc/ceilometer/ceilometer.conf DEFAULT rabbit_password "${RABBIT_PASS}"
elif [ $OSVERSION -lt $OSNEWTON ]; then
    crudini --set /etc/ceilometer/ceilometer.conf DEFAULT rpc_backend rabbit
    crudini --set /etc/ceilometer/ceilometer.conf oslo_messaging_rabbit \
	rabbit_host $CONTROLLER
    crudini --set /etc/ceilometer/ceilometer.conf oslo_messaging_rabbit \
	rabbit_userid ${RABBIT_USER}
    crudini --set /etc/ceilometer/ceilometer.conf oslo_messaging_rabbit \
	rabbit_password "${RABBIT_PASS}"
else
    crudini --set /etc/ceilometer/ceilometer.conf DEFAULT \
	transport_url $RABBIT_URL
fi

if [ $OSVERSION -lt $OSKILO ]; then
    crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	auth_uri http://${CONTROLLER}:5000/${KAPISTR}
    crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	identity_uri http://${CONTROLLER}:35357
    crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	admin_tenant_name service
    crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	admin_user ceilometer
    crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	admin_password "${CEILOMETER_PASS}"
else
    crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	auth_uri http://${CONTROLLER}:5000
    crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	auth_url http://${CONTROLLER}:35357
    if [ $OSVERSION -ge $OSMITAKA -o $KEYSTONEUSEMEMCACHE -eq 1 ]; then
	crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	    memcached_servers ${CONTROLLER}:11211
    fi
    crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	${AUTH_TYPE_PARAM} password
    crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	${PROJECT_DOMAIN_PARAM} default
    crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	${USER_DOMAIN_PARAM} default
    crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	project_name service
    crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	username ceilometer
    crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	password "$CEILOMETER_PASS"
    crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	region_name "$REGION"
fi

if [ $OSVERSION -lt $OSMITAKA ]; then
    crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
	os_auth_url http://${CONTROLLER}:5000/${KAPISTR}
    crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
	os_username ceilometer
    crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
	os_tenant_name service
    crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
	os_password ${CEILOMETER_PASS}
    if [ $OSVERSION -ge $OSKILO ]; then
	crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
	    os_endpoint_type internalURL
	crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
	    os_region_name $REGION
    fi
else
    crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
	${AUTH_TYPE_PARAM} password
    crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
	auth_url http://${CONTROLLER}:5000/${KAPISTR}
    crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
	username ceilometer
    crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
	project_name service
    crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
	password ${CEILOMETER_PASS}
    if [ $OSVERSION -ge $OSKILO ]; then
	crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
	    interface internalURL
	crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
	    region_name $REGION
    fi
    crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
        ${PROJECT_DOMAIN_PARAM} default
    crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
        ${USER_DOMAIN_PARAM} default
fi

crudini --set /etc/ceilometer/ceilometer.conf notification \
    store_events true
crudini --set /etc/ceilometer/ceilometer.conf notification \
    disable_non_metric_meters false

if [ $OSVERSION -le $OSJUNO ]; then
    crudini --set /etc/ceilometer/ceilometer.conf publisher \
	metering_secret ${CEILOMETER_SECRET}
else
    crudini --set /etc/ceilometer/ceilometer.conf publisher \
	telemetry_secret ${CEILOMETER_SECRET}
fi

crudini --del /etc/ceilometer/ceilometer.conf database connection
crudini --del /etc/ceilometer/ceilometer.conf DEFAULT auth_host
crudini --del /etc/ceilometer/ceilometer.conf DEFAULT auth_port
crudini --del /etc/ceilometer/ceilometer.conf DEFAULT auth_protocol

crudini --set /etc/nova/nova.conf DEFAULT instance_usage_audit True
crudini --set /etc/nova/nova.conf DEFAULT instance_usage_audit_period hour
crudini --set /etc/nova/nova.conf DEFAULT notify_on_state_change vm_and_task_state
if [ $OSVERSION -lt $OSMITAKA ]; then
    crudini --set /etc/nova/nova.conf DEFAULT notification_driver messagingv2
else
    crudini --set /etc/nova/nova.conf oslo_messaging_notifications driver messagingv2
fi

service_restart ceilometer-agent-compute
service_enable ceilometer-agent-compute
service_restart nova-compute
service_restart ceilometer-agent-compute

touch $OURDIR/setup-compute-telemetry-done

logtend "compute-telemetry"

exit 0
