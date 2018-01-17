#!/usr/bin/env python

##
## A simple Ceilometer script that runs within a Cloudlab OpenStack
## experiment and writes several resource utilization files into
## /root/openstack-slothd .
##
## This script runs every N minutes (default 10), and reports its
## metrics over 5 time periods: last 10 minutes, hour, 6 hours, day,
## week.  For each period, for each physical host in the experiment, it
## reports the number of distinct VMs that existed, CPU utilization for
## each VM, and network traffic for each VM.  
##

import os
import time
import sys
import hashlib
import logging
import traceback
import pprint
import json
import shutil
from ceilometerclient import client
from ceilometerclient.v2.query import QueryManager

VERSION = 1

CLOUDLAB_AUTH_FILE = '/root/setup/admin-openrc.py'
KEYSTONE_OPTS = [ 'OS_PROJECT_DOMAIN_ID','OS_USER_DOMAIN_ID',
                  'OS_PROJECT_NAME','OS_TENANT_NAME',
                  'OS_USERNAME','OS_PASSWORD','OS_AUTH_URL' ]
#'OS_IDENTITY_API_VERSION'

#
# We often want to see "everything", and ceilometer limits us by
# default, so assume "everything" falls into UINT32_MAX.  What a mess.
#
LIMIT = 0xffffffff
MINUTE = 60
HOUR = MINUTE * 60
DAY = HOUR * 24
WEEK = DAY * 7
EPOCH = '__EPOCH__'

PERIODS = [10*MINUTE,HOUR,6*HOUR,DAY,WEEK,EPOCH]

INTERVALS = { DAY  : 5 * MINUTE,
              WEEK : HOUR }

OURDIR = '/root/setup'
OUTDIR = '/root/setup'
OUTBASENAME = 'cloudlab-openstack-stats.json'
OURDOMAIN = None

USE_PRELOAD_RESOURCES = False
USE_UUID_MAP = False

projects = {}
resources = {}
vhostnames = {}
phostnames = {}
r_hostnames = {}

uuidmap = {}
uuidmap_counter = 0

LOG = logging.getLogger(__name__)
# Define a default handler at INFO logging level
logging.basicConfig(level=logging.INFO)

pp = pprint.PrettyPrinter(indent=2)

DMETERS = ['cpu_util','network.incoming.bytes.rate',
           'network.outgoing.bytes.rate']
# We no longer collect these meters for periods; for periods,
# all we collect are the event meters.  We collect the DMETERS
# only for intervals now.
PERIOD_DMETERS = [ 'instance' ]
# NB: very important that the .delete meters come first, for
# each resource type.  Why?  Because we only put the resource
# details into the info dict one time (because we don't know
# how to merge details for a given resource if we see it again
# later and it differs) -- and sometimes we know if a resource
# is deleted based on if the delete method has been called for
# it (i.e. for network resources); for other resources like
# images, there's a deleted bit in the metadata we can just read.
EMETERS = [ 'network.delete','network.create','network.update',
            'subnet.delete','subnet.create','subnet.update',
#            'port.delete','port.create','port.update',
            'router.delete','router.create','router.update',
            'image.upload','image.update' ]

HELP = {
    'Summary': \
      'This is a summary of OpenStack resource usage in your experiment over' \
      ' several prior time periods (the last 10 minutes, hour, 6 hours, day,' \
      ' and week).  It is collected by a simple Ceilometer script that' \
      ' requests statistics from several OpenStack Ceilometer meters.' \
      ' Because we\'re primarily interested in resource usage on a' \
      ' per-physical-node basis, metrics and events are grouped by the' \
      ' physical node that used the resource in question or originated the' \
      ' event, and we show totals for the physical machine, as well as the' \
      ' per-resource fine-grained metric value.  We collect several meter' \
      ' values, including CPU utilization, network traffic, and API events.' \
      ' These are described in more detail in the subsequent keys.  Finally,' \
      ' some detailed metadata (i.e., VM disk image, name, etc) each' \
      ' OpenStack resource measured by a meter during one of our time' \
      ' periods is placed in the top-level dict under the \'info\' key.',
    
    'cpu_util': \
      'An average of CPU utilization (percent) over the given time period.' \
      ' OpenStack polls each VM\'s real CPU usage time at intervals, and the' \
      ' difference in usage between polling intervals is used to calculate' \
      ' the average CPU utilization over the interval.',
    'network.incoming.bytes.rate': \
      'The average rate of incoming network traffic to VMs.  OpenStack' \
      ' collects cumulative samples at intervals of VM bandwidth usage,' \
      ' and these samples are used to calculate a rate.  We then take the ' \
      ' average of all rate "samples" over our time periods.',
    'network.outgoing.bytes.rate': \
      'The average rate of outgoing network traffic from VMs.  OpenStack' \
      ' collects cumulative samples at intervals of VM bandwidth usage,' \
      ' and these samples are used to calculate a rate.  We then take the ' \
      ' average of all rate "samples" over our time periods.',

    'network.delete': \
      'The number of OpenStack virtual networks deleted during the period.',
    'network.create': \
      'The number of OpenStack virtual networks created during the period.',
    'network.update': \
      'The number of OpenStack virtual networks updated during the period.',
    'subnet.delete': \
      'The number of OpenStack virtual subnets deleted during the period.',
    'subnet.create': \
      'The number of OpenStack virtual subnets created during the period.',
    'subnet.update': \
      'The number of OpenStack virtual subnets updated during the period.',
    'port.delete': \
      'The number of OpenStack virtual network ports deleted during the period.',
    'port.create': \
      'The number of OpenStack virtual network ports created during the period.',
    'port.update': \
      'The number of OpenStack virtual network ports updated during the period.',
    'router.delete': \
      'The number of OpenStack virtual network routers deleted during the period.',
    'router.create': \
      'The number of OpenStack virtual network routers created during the period.',
    'router.update': \
      'The number of OpenStack virtual network routers updated during the period.',
    'image.upload': \
      'The number of images uploaded during the period.',
    'image.update': \
      'The number of images updated during the period.',
}

def build_keystone_args():
    global KEYSTONE_OPTS, CLOUDLAB_AUTH_FILE
    
    ret = dict()
    # First, see if they're in the env:
    for opt in KEYSTONE_OPTS:
        if opt in os.environ:
            ret[opt.lower()] = os.environ[opt]
        pass
    # Second, see if they're in a special Cloudlab file:
    if os.geteuid() == 0 and os.path.exists(CLOUDLAB_AUTH_FILE):
        try:
            f = open(CLOUDLAB_AUTH_FILE,'r')
            while True:
                line = f.readline()
                if not line:
                    break
                line = line.rstrip('\n')
                vva = line.split('=')
                if not vva or len(vva) != 2:
                    continue
                
                ret[vva[0].lower()] = eval(vva[1])

                pass
            f.close()
        except:
            LOG.exception("could not build keystone args!")
        pass
    elif os.geteuid() != 0:
        LOG.warn("you are not root (%d); not checking %s",os.geteuid(),CLOUDLAB_AUTH_FILE)
    elif not os.path.exists(CLOUDLAB_AUTH_FILE):
        LOG.warn("%s does not exist; not loading auth opts from it",CLOUDLAB_AUTH_FILE)

    return ret

def get_resource(client,resource_id):
    global resources,projects
    
    r = None
    if not resource_id in resources:
        r = client.resources.get(resource_id)
        resources[resource_id] = r
    else:
        r = resources[resource_id]
        pass
    
    return r

def get_hypervisor_hostname(client,resource):
    global resources,projects,r_hostnames
    
    #
    # This is yucky.  I have seen two different cases: one where the
    # resource.metadata.host field is a hash of the project_id and
    # hypervisor hostname -- and a second one (after a reboot) where the
    # 'host' field looks like 'compute.<HYPERVISOR-FQDN>' and there is a
    # 'node' field that has the hypervisor FQDN.  So we try to place
    # nice for both cases... use the 'node' field if it exists --
    # otherwise assume that the 'host' field has a hash.  Ugh!
    #
    # Ok, I see how this works.  If you call client.resources.list(),
    # you are shown a hash for the 'host' field.  And if you call
    # client.resources.get(resource_id) (presumably as admin, like we
    # do), you get more info.  Now, why can't they just do the same for
    # client.resources.list()?!  Anyway, we just choose not to
    # pre-initialize the resources list above, at startup, and pull them
    # all on-demand.
    #
    # Well, that was a nice theory, but it doesn't seem deterministic.  I
    # wonder if there's some kind of race.  Anyway, have to leave all this
    # hash crap in here for now.
    #
    if 'node' in resource.metadata \
      and resource.metadata['node'].endswith(OURDOMAIN):
        hostname = resource.metadata['node']
    elif 'host' in resource.metadata \
      and resource.metadata['host'].startswith('compute.') \
      and resource.metadata['host'].endswith(OURDOMAIN):
        hostname = resource.metadata['host'].lstrip('compute.')
    else:
        if not resource.project_id in projects:
            projects[resource.project_id] = resource.project_id
            for hostname in vhostnames.keys():
                shash = hashlib.sha224(resource.project_id + hostname)
                hh = shash.hexdigest()
                r_hostnames[hh] = hostname
                pass
            pass
        #LOG.debug("resource: " + pp.pformat(resource))
        hh = None
        try:
            hh = resource.metadata['host']
        except:
            if 'instance_id' in resource.metadata:
                LOG.debug("no hostname info for resource %s; trying instance_id" % (str(resource),))
                return get_hypervisor_hostname(client,get_resource(client,resource.metadata['instance_id']))
            else:
                LOG.exception("no 'host' field in metadata for resource %s" % (str(resource,)))
            pass
        if not hh in r_hostnames.keys():
            LOG.error("hostname hash %s doesn't map to a known hypervisor hostname!" % (hh,))
            return None
        hostname = r_hostnames[hh]
        pass
    return hostname

def get_api_hostname(client,resource):
    if 'host' in resource.metadata:
        if resource.metadata['host'].startswith('compute.') \
          and resource.metadata['host'].endswith(OURDOMAIN):
            return resource.metadata['host'].lstrip('compute.')
        elif resource.metadata['host'].startswith('network.') \
          and resource.metadata['host'].endswith(OURDOMAIN):
            return resource.metadata['host'].lstrip('network.')
        pass
    return None

def get_short_uuid(uuid):
    global uuidmap,uuidmap_counter

    if not USE_UUID_MAP:
        return uuid
    
    if uuid in uuidmap:
        return uuidmap[uuid]

    uuidmap_counter += 1
    uuidmap[uuid] = "uu" + str(uuidmap_counter)
    return uuidmap[uuid]

def fetchall(client):
    tt = time.gmtime()
    ct = time.mktime(tt)
    cts = time.strftime('%Y-%m-%dT%H:%M:%S',tt)

    periods = {}
    intervals = {}
    info = {}
    #datadict = {}
    vm_dict = dict() #count=vm_0,list=[])
    
    #
    # Ok, collect all the statistics, grouped by VM, for the period.  We
    # have to specify this duration
    #
    for period in PERIODS:
        periodkey = period
        if period == EPOCH:
            period = time.time()
            pass
        
        periods[periodkey] = {}
        cpu_util_dict = dict()
        
        daylightfactor = 0
        if time.daylight:
            daylightfactor -= HOUR
            pass
        
        pct = ct - period + daylightfactor
        ptt = time.localtime(pct)
        pcts = time.strftime('%Y-%m-%dT%H:%M:%S',ptt)
        q = [{'field':'timestamp','value':pcts,'op':'ge',},
             {'field':'timestamp','value':cts,'op':'lt',}]

        # First, query some rate meters for avg stats:
        for meter in PERIOD_DMETERS:
            LOG.info("getting statistics for meter %s during period %s"
                     % (meter,str(period)))
            mdict = {}
            statistics = client.statistics.list(meter,#period=period,
                                                groupby=['resource_id'],
                                                q=q)
            LOG.debug("Statistics for %s during period %d (len %d): %s"
                      % (meter,period,len(statistics),pp.pformat(statistics)))
            for stat in statistics:
                rid = stat.groupby['resource_id']
                resource = get_resource(client,rid)
                # For whatever reason, the resource_id for the network.*
                # meters prefixes the VM UUIDs with instance-%d- ...
                # so strip that out.
                vmrid = rid
                if rid.startswith('instance-'):
                    vmrid = rid.lstrip('instance-')
                    vidx = vmrid.find('-')
                    vmrid = vmrid[(vidx+1):]
                    pass
                # Then, for the network.* meters, the results are
                # per-interface, so strip that off too so we can
                # report one number per VM.
                vidx = vmrid.find('-tap')
                if vidx > -1:
                    vmrid = vmrid[:vidx]
                    pass

                vmrid = get_short_uuid(vmrid)
                
                hostname = get_hypervisor_hostname(client,resource)
                LOG.debug("%s for %s on %s = %f (resource=%s)"
                          % (meter,rid,hostname,stat.avg,pp.pformat(resource)))
                if not hostname in vm_dict:
                    vm_dict[hostname] = {}
                    pass
                if not vmrid in vm_dict[hostname]:
                    vm_dict[hostname][vmrid] = {}
                if not 'name' in vm_dict[hostname][vmrid] \
                   and 'display_name' in resource.metadata:
                    vm_dict[hostname][vmrid]['name'] = resource.metadata['display_name']
                if not 'image' in vm_dict[hostname][vmrid] \
                   and 'image.name' in resource.metadata:
                    vm_dict[hostname][vmrid]['image'] = resource.metadata['image.name']
                if not 'status' in vm_dict[hostname][vmrid] \
                   and 'status' in resource.metadata:
                    vm_dict[hostname][vmrid]['status'] = resource.metadata['status']
                    pass
                if not hostname in mdict:
                    mdict[hostname] = dict(total=0.0,vms={})
                    pass
                mdict[hostname]['total'] += round(stat.avg,4)
                if not vmrid in mdict[hostname]['vms']:
                    mdict[hostname]['vms'][vmrid] = round(stat.avg,4)
                else:
                    mdict[hostname]['vms'][vmrid] += round(stat.avg,4)
                    pass
                pass
            periods[periodkey][meter] = mdict
            pass
        
        
        info['vms'] = vm_dict

        # Now also query the API delta meters:
        rdicts = dict()
        for meter in EMETERS:
            LOG.info("getting statistics for event meter %s during period %s"
                     % (meter,str(period)))
            idx = meter.find('.')
            if idx > -1:
                rplural = "%s%s" % (meter[0:idx],'s')
            else:
                rplural = None
                pass
            if rplural and not rplural in rdicts:
                rdicts[rplural] = dict()
                pass
            mdict = {}
            statistics = client.statistics.list(meter,#period=period,
                                                groupby=['resource_id'],
                                                q=q)
            LOG.debug("Statistics for %s during period %d (len %d): %s"
                      % (meter,period,len(statistics),pp.pformat(statistics)))
            for stat in statistics:
                rid = stat.groupby['resource_id']
                resource = get_resource(client,rid)
                rid = get_short_uuid(rid)
                hostname = get_api_hostname(client,resource)
                if not hostname:
                    hostname = 'UNKNOWN'
                    pass
                LOG.debug("%s for %s on %s = %f (%s)"
                          % (meter,rid,hostname,stat.sum,pp.pformat(resource)))
                if rplural and not rid in rdicts[rplural]:
                    deleted = False
                    if meter.endswith('.delete') \
                       or ('deleted' in resource.metadata \
                           and resource.metadata['deleted'] \
                                 in ['True','true',True]):
                        deleted = True
                        pass
                    rmname = None
                    if 'name' in resource.metadata:
                        rmname = resource.metadata['name']
                    rdicts[rplural][rid] = dict(name=rmname,
                                                deleted=deleted)
                    status = None
                    if 'state' in resource.metadata:
                        status = resource.metadata['state']
                    elif 'status' in resource.metadata:
                        status = resource.metadata['status']
                        pass
                    if not status is None:
                        rdicts[rplural][rid]['status'] = str(status).lower()
                        pass
                    pass
                if rplural:
                    rname = rplural
                else:
                    rname = 'resources'
                    pass
                if not hostname in mdict:
                    mdict[hostname] = { 'total':0.0,rname:{} }
                    pass
                mdict[hostname]['total'] += stat.sum
                mdict[hostname][rname][rid] = stat.sum
                pass
            periods[periodkey][meter] = mdict
            pass
        for (res,infodict) in rdicts.iteritems():
            # If we haven't seen this resource before, slap all
            # the info we've found for all those resource ids
            # into our info dict for this resource type.  Else,
            # carefully merge -- if we've already collected info
            # for a specific resource, don't overwrite that.
            # The theory for the Else case is that newer info
            # is better, if the older info differs (which I can't
            # think right now it would... should be the same for
            # all periods).
            if not res in info:
                info[res] = infodict
            else:
                for (resid,resinfodict) in infodict.iteritems():
                    if not resid in info[res]:
                        info[res][resid] = resinfodict
                pass
            pass
        pass
        
    #
    # Now query the same meters, but for 5-minute intervals over the
    # past 24 hours, and for 1-hr intervals over the past week.
    #
    for (period,interval) in INTERVALS.iteritems():
        intervals[period] = {}
        cpu_util_dict = dict()
        
        daylightfactor = 0
        if time.daylight:
            daylightfactor -= HOUR
            pass
        
        pct = ct - period + daylightfactor
        ptt = time.localtime(pct)
        pcts = time.strftime('%Y-%m-%dT%H:%M:%S',ptt)
        q = [{'field':'timestamp','value':pcts,'op':'ge',},
             {'field':'timestamp','value':cts,'op':'lt',}]

        # First, query some rate meters for avg stats:
        for meter in DMETERS:
            LOG.info("getting statistics for meter %s during period %s interval %s"
                     % (meter,str(period),str(interval)))
            mdict = {}
            statistics = client.statistics.list(meter,period=interval,
                                                groupby=['resource_id'],
                                                q=q)
            LOG.debug("Statistics (interval %d) for %s during period %d"
                      " (len %d): %s"
                      % (interval,meter,period,len(statistics),
                         pp.pformat(statistics)))
            for stat in statistics:
                rid = stat.groupby['resource_id']
                resource = get_resource(client,rid)
                # For whatever reason, the resource_id for the network.*
                # meters prefixes the VM UUIDs with instance-%d- ...
                # so strip that out.
                vmrid = rid
                if rid.startswith('instance-'):
                    vmrid = rid.lstrip('instance-')
                    vidx = vmrid.find('-')
                    vmrid = vmrid[(vidx+1):]
                    pass
                # Then, for the network.* meters, the results are
                # per-interface, so strip that off too so we can
                # report one number per VM.
                vidx = vmrid.find('-tap')
                if vidx > -1:
                    vmrid = vmrid[:vidx]
                    pass

                vmrid = get_short_uuid(vmrid)
                
                hostname = get_hypervisor_hostname(client,resource)
                LOG.debug("%s for %s on %s = %f (resource=%s)"
                          % (meter,rid,hostname,stat.avg,pp.pformat(resource)))
                if not hostname in vm_dict:
                    vm_dict[hostname] = {}
                    pass
                if not vmrid in vm_dict[hostname]:
                    vm_dict[hostname][vmrid] = {}
                if not 'name' in vm_dict[hostname][vmrid] \
                   and 'display_name' in resource.metadata:
                    vm_dict[hostname][vmrid]['name'] = resource.metadata['display_name']
                if not 'image' in vm_dict[hostname][vmrid] \
                   and 'image.name' in resource.metadata:
                    vm_dict[hostname][vmrid]['image'] = resource.metadata['image.name']
                if not 'status' in vm_dict[hostname][vmrid] \
                   and 'status' in resource.metadata:
                    vm_dict[hostname][vmrid]['status'] = resource.metadata['status']
                    pass
                if not hostname in mdict:
                    mdict[hostname] = dict(vms={}) #dict(total=0.0,vms={})
                    pass
                #mdict[hostname]['total'] += stat.avg
                if not vmrid in mdict[hostname]['vms']:
                    mdict[hostname]['vms'][vmrid] = {}
                    #mdict[hostname]['vms'][vmrid] = {'__FLATTEN__':True}
                    pass
                pet = time.strptime(stat.period_end,'%Y-%m-%dT%H:%M:%S')
                pes = time.mktime(pet)
                mdict[hostname]['vms'][vmrid][pes] = \
                  dict(avg=round(stat.avg,4),max=round(stat.max,4),n=round(stat.count,4))
                pass
            intervals[period][meter] = mdict
            pass
        pass
    
    info['vms'] = vm_dict
    info['host2vname'] = vhostnames
    info['host2pnode'] = phostnames
    info['uuidmap'] = uuidmap

    ett = time.gmtime()
    ect = time.mktime(ett)
    ects = time.strftime('%Y-%m-%dT%H:%M:%S',ett)
    gmoffset = time.timezone
    daylight = False
    if time.daylight:
        gmoffset = time.altzone
        daylight = True
        pass

    metadata = dict(start=cts,start_timestamp=ct,
                    end=ects,end_timestamp=ect,
                    duration=(ect-ct),gmoffset=gmoffset,
                    daylight=daylight,version=VERSION,
                    periods=PERIODS,intervals=INTERVALS)
    
    return dict(periods=periods,intervals=intervals,info=info,META=metadata,HELP=HELP)

def preload_resources(client):
    global resources

    resourcelist = client.resources.list(limit=LIMIT)
    LOG.debug("Resources: " + pp.pformat(resourcelist))
    for r in resourcelist:
        resources[r.id] = r
        pass
    pass

def reload_hostnames():
    global vhostnames,phostnames,OURDOMAIN
    newvhostnames = {}
    newphostnames = {}
    
    try:
        f = file(OURDIR + "/fqdn.map")
        i = 0
        for line in f:
            i += 1
            if len(line) == 0 or line[0] == '#':
                continue
            line = line.rstrip('\n')
            la = line.split("\t")
            if len(la) != 2:
                LOG.warn("bad FQDN line %d; skipping" % (i,))
                continue
            vname = la[0].lower()
            fqdn = la[1].lower()
            newvhostnames[fqdn] = vname
            if OURDOMAIN is None or OURDOMAIN == '':
                idx = fqdn.find('.')
                if idx > -1:
                    OURDOMAIN = fqdn[idx+1:]
                pass
            pass
        vhostnames = newvhostnames
        
        f = file(OURDIR + "/fqdn.physical.map")
        i = 0
        for line in f:
            i += 1
            if len(line) == 0 or line[0] == '#':
                continue
            line = line.rstrip('\n')
            la = line.split("\t")
            if len(la) != 2:
                LOG.warn("bad FQDN line %d; skipping" % (i,))
                continue
            pname = la[0].lower()
            fqdn = la[1].lower()
            newphostnames[fqdn] = pname
            pass
        phostnames = newphostnames
    except:
        LOG.exception("failed to reload hostnames, returning None")
        pass
    return

def main():
    try:
        os.makedirs(OUTDIR)
    except:
        pass
    kargs = build_keystone_args()
    LOG.debug("keystone args: %s" % (str(kargs)))
    
    cclient = client.get_client(2,**kargs)
    
    if USE_PRELOAD_RESOURCES:
        preload_resources(cclient)
        pass
    
    iteration = 0
    outfile = "%s/%s" % (OUTDIR,OUTBASENAME)
    tmpoutfile = outfile + ".NEW"
    while True:
        iteration += 1
        try:
            reload_hostnames()
            newdatadict = fetchall(cclient)
            f = file(tmpoutfile,'w')
            #,cls=FlatteningJSONEncoder)
            f.write(json.dumps(newdatadict,sort_keys=True,indent=None) + '\n')
            f.close()
            shutil.move(tmpoutfile,outfile)
        except:
            LOG.exception("failure during iteration %d; nothing new generated"
                          % (iteration,))
            pass
        
        LOG.debug("Sleeping for 5 minutes...")
        time.sleep(5 * MINUTE)
        pass

    #meters = client.meters.list(limit=LIMIT)
    #pp.pprint("Meters: ")
    #pp.pprint(meters)
    
    # Ceilometer meter.list command only allows filtering on
    # ['project', 'resource', 'source', 'user'].
    # q=[{'field':'meter.name','value':'cpu_util','op':'eq','type':'string'}]
    #cpu_util_meters = []
    #for m in meters:
    #    if m.name == 'cpu_util':
    #        cpu_util_meters.append(m)
    #    pass
    #pp.pprint("cpu_util Meters:")
    #pp.pprint(cpu_util_meters)
    
    #for m in cpu_util_meters:
    #    pp.pprint("Resource %s for cpu_util meter %s:" % (m.resource_id,m.meter_id))
    #    pp.pprint(resources[m.resource_id])
    #    pass
    
    return -1

if __name__ == "__main__":
    main()
