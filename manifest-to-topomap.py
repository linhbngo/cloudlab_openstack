#!/usr/bin/env python2

import sys
import lxml.etree

iface_link_map = {}
link_members = {}
node_ifaces = {}
link_netmasks = {}
allifaces = {}

f = open(sys.argv[1],'r')
contents = f.read()
f.close()
root = lxml.etree.fromstring(contents)

# Find all the links:
for elm in root.getchildren():
    if not elm.tag.endswith("}link"):
        continue
    name = elm.get("client_id")
    ifacerefs = []
    for elm2 in elm.getchildren():
        if not elm2.tag.endswith("}interface_ref"):
            continue
        ifacename = elm2.get("client_id")
        ifacerefs.append(ifacename)
        iface_link_map[ifacename] = name
    link_members[name] = ifacerefs

# Find all the node interfaces
for elm in root.getchildren():
    if not elm.tag.endswith("}node"):
        continue
    name = elm.get("client_id")
    ifaces = {}
    for elm2 in elm.getchildren():
        if not elm2.tag.endswith("}interface"):
            continue
        ifacename = elm2.get("client_id")
        for elm3 in elm2.getchildren():
            if not elm3.tag.endswith("}ip"):
                continue
            if not elm3.get("type") == 'ipv4':
                continue
            addrtuple = (elm3.get("address"),elm3.get("netmask"))
            ifaces[ifacename] = addrtuple
            allifaces[ifacename] = addrtuple
            break
    node_ifaces[name] = ifaces

# Dump the nodes a la topomap
print "# nodes: vname,links"
for n in node_ifaces.keys():
    for (i,(addr,mask)) in node_ifaces[n].iteritems():
        print "%s,%s:%s" % (n,iface_link_map[i],addr)

# Dump the links a la topomap -- but with fixed cost of 1
print "# lans: vname,mask,cost"
for m in link_members.keys():
    ifref = link_members[m][0]
    (ip,mask) = allifaces[ifref]
    print "%s,%s,1" % (m,mask)

sys.exit(0)
