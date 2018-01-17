#!/usr/bin/env python

import sys
import subprocess
from keystoneclient.auth.identity import v2
try:
    from keystoneclient.auth.identity import v3
except:
    pass
from keystoneclient import session
from novaclient.client import Client
import sys
import pwd
import getopt
import os
import os.path
import re
import xmlrpclib
from M2Crypto import X509
import os.path
#import keystoneclient
#import novaclient
import traceback
import logging

LOG = logging.getLogger(__name__)
# Define a default handler at INFO logging level
logging.basicConfig(level=logging.INFO)

CLOUDLAB_SETTINGS_FILE = '/root/setup/settings'
CLOUDLAB_AUTH_FILE = '/root/setup/admin-openrc.py'
KEYSTONE_OPTS = [ 'OS_PROJECT_DOMAIN_ID','OS_USER_DOMAIN_ID',
                  'OS_PROJECT_DOMAIN_NAME','OS_USER_DOMAIN_NAME',
                  'OS_PROJECT_NAME','OS_TENANT_NAME',
                  'OS_USERNAME','OS_PASSWORD','OS_AUTH_URL' ]
#'OS_IDENTITY_API_VERSION'

execfile(CLOUDLAB_SETTINGS_FILE)
execfile(CLOUDLAB_AUTH_FILE)

dirname = os.path.abspath(os.path.dirname(sys.argv[0]))
execfile("%s/test-common.py" % (dirname,))

#
# Convert the certificate into a credential.
#
params = {}
rval,response = do_method("", "GetCredential", params)
if rval:
    Fatal("Could not get my credential")
    pass
mycredential = response["value"]

params["credential"] = mycredential
rval,response = do_method("", "GetSSHKeys", params)
if rval:
    Fatal("Could not get ssh keys")
    pass

#
# This is really, really ugly.  So, keystone and nova don't offer us a way to
# upload keypairs on behalf of another user.  Recall, we're using the adminapi
# account to do all this setup, because we don't know the admin password.  So,
# the below code adds all the keys as 'adminapi', then we dump the sql, do some
# sed magic on it to get rid of the primary key and change the user_id to the
# real admin user_id, then we insert those rows, then we cleanup the lint.  By
# doing it this way, we eliminate our dependency on the SQL format and column
# names and semantics.  We make two assumptions: 1) that there is only one field
# that has integer values, and 2) the only field that is an exception to #1 is
# called 'deleted' and we just set those all to 0 after we jack the whacked sql
# in.  Ugh, it's worse than I hoped, but whatever.
#
# This is one of the sickest one-liners I've ever come up with.
#

def build_keystone_args():
    global KEYSTONE_OPTS, CLOUDLAB_AUTH_FILE
    
    ret = dict()
    # First, see if they're in the env:
    for opt in KEYSTONE_OPTS:
        if opt in os.environ:
            ret[opt[3:].lower()] = os.environ[opt]
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
                if not vva[0] in KEYSTONE_OPTS:
                    continue
                
                ret[vva[0][3:].lower()] = eval(vva[1])

                pass
            f.close()
        except:
            LOG.exception("could not build keystone args!")
        pass
    elif os.geteuid() != 0:
        LOG.warn("you are not root (%d); not checking %s",os.geteuid(),CLOUDLAB_AUTH_FILE)
    elif not os.path.exists(CLOUDLAB_AUTH_FILE):
        LOG.warn("%s does not exist; not loading auth opts from it",CLOUDLAB_AUTH_FILE)
        pass
    
    # A hack for v3, because of how we write the admin-openrc.py file
    if 'project_name' in ret and 'tenant_name' in ret:
        del ret['tenant_name']
        pass
    
    return ret

kargs = build_keystone_args()
if 'project_domain_name' in kargs or 'project_domain_id' in kargs:
    auth = v3.Password(**kargs)
else:
    auth = v2.Password(**kargs) #auth_url=url,username=ADMIN_API,password=ADMIN_API_PASS,tenant_name='admin')
    pass
sess = session.Session(auth=auth)
nova = Client(2,session=sess)

keysdone = dict({})

for userdict in response['value']:
    urn = userdict['urn']
    login = userdict['login']
    for keydict in userdict['keys']:
        if not keydict.has_key('type') or keydict['type'] != 'ssh':
            continue
        
        key = keydict['key']
            
        posn = key.rindex(' ')
        name = key[posn+1:]
        rname = login + "-"
        for c in name:
            if c.isalpha():
                rname += c
            else:
                rname += 'X'
            pass
        
        if not keysdone.has_key(rname):
            try:
                nova.keypairs.create(rname,key)
                keysdone[rname] = key
            except:
                LOG.exception("failed to create keypair(%s,%s)"
                              % (rname,key))
            pass
        pass
    pass

#
# Ok, do the sick hack...
#
if OS_IDENTITY_API_VERSION == 3:
    try:
        user_domain_id_or_name = OS_USER_DOMAIN_ID
        user_domain_id_or_name_param = '--os-user-domain-id'
        project_domain_id_or_name = OS_PROJECT_DOMAIN_ID
        project_domain_id_or_name_param = '--os-project-domain-id'
    except:
        pass
    try:
        user_domain_id_or_name = OS_USER_DOMAIN_NAME
        user_domain_id_or_name_param = '--os-user-domain-name'
        project_domain_id_or_name = OS_PROJECT_DOMAIN_NAME
        project_domain_id_or_name_param = '--os-project-domain-name'
    except:
        pass
    os_cred_stuff = "openstack --os-username %s --os-password %s --os-tenant-name %s --os-auth-url %s %s %s %s %s --os-project-name %s --os-identity-api-version %s user list" % (OS_USERNAME,OS_PASSWORD,OS_TENANT_NAME,OS_AUTH_URL,user_domain_id_or_name_param,user_domain_id_or_name,project_domain_id_or_name_param,project_domain_id_or_name,OS_PROJECT_NAME,str(OS_IDENTITY_API_VERSION))
else:
    os_cred_stuff = "keystone --os-username %s --os-password %s --os-tenant-name %s --os-auth-url %s user-list " % (OS_USERNAME,OS_PASSWORD,OS_TENANT_NAME,OS_AUTH_URL,)
    pass

#  where user_id=\'${AUID}\'
cmd = 'export AAUID="`%s | awk \'/ adminapi / {print $2}\'`" ; export AUID="`%s | awk \'/ admin / {print $2}\'`" ; mysqldump -u nova --password=%s nova -t key_pairs --skip-comments --quote-names --no-create-info --no-create-db --complete-insert --compact | sed -e \'s/,[0-9]*,/,NULL,/gi\' | sed -e "s/,\'${AAUID}\',/,\'${AUID}\',/gi" | mysql -u nova --password=%s nova ; echo "update key_pairs set deleted=0" | mysql -u nova --password=%s nova' % (os_cred_stuff,os_cred_stuff,NOVA_DBPASS,NOVA_DBPASS,NOVA_DBPASS,)
#cmd = 'export OS_PASSWORD="%s" ; export OS_AUTH_URL="%s" ; export OS_USERNAME="%s" ; export OS_TENANT_NAME="%s" ; export AAUID="`keystone user-list | awk \'/ adminapi / {print $2}\'`" ; export AUID="`keystone user-list | awk \'/ admin / {print $2}\'`" ; mysqldump -u nova --password=%s nova -t key_pairs --skip-comments --quote-names --no-create-info --no-create-db --complete-insert --compact | sed -e \'s/,[0-9]*,/,NULL,/gi\' | sed -e "s/,\'${AAUID}\',/,\'${AUID}\',/gi" | mysql -u nova --password=%s nova ; echo "update key_pairs set deleted=0 where user_id=\'${AUID}\'" | mysql -u nova --password=%s nova' % (OS_PASSWORD,OS_AUTH_URL,OS_USERNAME,OS_PASSWORD,NOVA_DBPASS,NOVA_DBPASS,NOVA_DBPASS,)
print "Running adminapi -> admin key import: %s..." % (cmd,)
os.system(cmd)

#
# Ugh, the tables are now split between nova and nova_api ... so just do this too.
#
cmd = 'export AAUID="`%s | awk \'/ adminapi / {print $2}\'`" ; export AUID="`%s | awk \'/ admin / {print $2}\'`" ; mysqldump -u nova --password=%s nova_api -t key_pairs --skip-comments --quote-names --no-create-info --no-create-db --complete-insert --compact | sed -e \'s/,[0-9]*,/,NULL,/gi\' | sed -e "s/,\'${AAUID}\',/,\'${AUID}\',/gi" | mysql -u nova --password=%s nova_api ; echo "update key_pairs set deleted=0" | mysql -u nova_api --password=%s nova' % (os_cred_stuff,os_cred_stuff,NOVA_DBPASS,NOVA_DBPASS,NOVA_DBPASS,)
print "Running adminapi -> admin key import: %s..." % (cmd,)
os.system(cmd)

sys.exit(0)
