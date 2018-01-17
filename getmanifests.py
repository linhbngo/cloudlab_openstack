#! /usr/bin/env python
#
# Copyright (c) 2008-2009, 2015 University of Utah and the Flux Group.
# 
# {{{GENIPUBLIC-LICENSE
# 
# GENI Public License
# 
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and/or hardware specification (the "Work") to
# deal in the Work without restriction, including without limitation the
# rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Work, and to permit persons to whom the Work
# is furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Work.
# 
# THE WORK IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
# OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
# HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
# WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE WORK OR THE USE OR OTHER DEALINGS
# IN THE WORK.
# 
# }}}
#

#
#
import sys
import pwd
import getopt
import os
import re
import xmlrpclib
from M2Crypto import X509
import os.path

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
rval,response = do_method("", "GetManifests", params)
if rval:
    Fatal("Could not get manifests")
    pass
if len(sys.argv) < 2:
    print response["value"]
else:
    f = open("%s.xml" % (sys.argv[1],),'w')
    value = response["value"]["manifests"]
    i = 0
    for key in value.keys():
        f2 = open("%s.%d.xml" % (sys.argv[1],i,),'w')
        f2.write(value[key])
        f2.close()
        i += 1
        f.write(value[key])
        pass
    f.close()
    pass
