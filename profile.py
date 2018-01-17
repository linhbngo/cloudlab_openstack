#!/usr/bin/env python

import geni.portal as portal
import geni.rspec.pg as RSpec
import geni.rspec.igext as IG
# Emulab specific extensions.
import geni.rspec.emulab as emulab
from lxml import etree as ET
import crypt
import random
import os.path
import sys

TBURL = "http://www.emulab.net/downloads/openstack-setup-v33.tar.gz"
TBCMD = "sudo mkdir -p /root/setup && (if [ -d /local/repository ]; then sudo -H /local/repository/setup-driver.sh 2>&1 | sudo tee /root/setup/setup-driver.log; else sudo -H /tmp/setup/setup-driver.sh 2>&1 | sudo tee /root/setup/setup-driver.log; fi)"

#
# For now, disable the testbed's root ssh key service until we can remove ours.
# It seems to race (rarely) with our startup scripts.
#
disableTestbedRootKeys = True

#
# Create our in-memory model of the RSpec -- the resources we're going to request
# in our experiment, and their configuration.
#
rspec = RSpec.Request()

#
# This geni-lib script is designed to run in the CloudLab Portal.
#
pc = portal.Context()

#
# Define *many* parameters; see the help docs in geni-lib to learn how to modify.
#
pc.defineParameter("release","OpenStack Release",
                   portal.ParameterType.STRING,"pike",[("pike","Pike"),("ocata","Ocata"),("newton","Newton"),("mitaka","Mitaka"),("liberty","Liberty (deprecated)"),("kilo","Kilo (deprecated)"),("juno","Juno (deprecated)")],
                   longDescription="We provide OpenStack Pike, Ocata, Newton, Mitaka (Ubuntu 16.04); Liberty (Ubuntu 15.10); Kilo (Ubuntu 15.04); or Juno (Ubuntu 14.10).  OpenStack is installed from packages available on these distributions.")
pc.defineParameter("computeNodeCount", "Number of compute nodes (at Site 1)",
                   portal.ParameterType.INTEGER, 1)
pc.defineParameter("osNodeType", "Hardware Type",
                   portal.ParameterType.NODETYPE, "",
                   longDescription="A specific hardware type to use for each node.  Cloudlab clusters all have machines of specific types.  When you set this field to a value that is a specific hardware type, you will only be able to instantiate this profile on clusters with machines of that type.  If unset, when you instantiate the profile, the resulting experiment may have machines of any available type allocated.")
pc.defineParameter("osLinkSpeed", "Experiment Link Speed",
                   portal.ParameterType.INTEGER, 0,
                   [(0,"Any"),(1000000,"1Gb/s"),(10000000,"10Gb/s")],
                   longDescription="A specific link speed to use for each node.  All experiment network interfaces will request this speed.")
pc.defineParameter("ml2plugin","ML2 Plugin",
                   portal.ParameterType.STRING,"openvswitch",
                   [("openvswitch","OpenVSwitch"),
                    ("linuxbridge","Linux Bridge")],
                   longDescription="Starting in Liberty and onwards, we support both the OpenVSwitch and LinuxBridge ML2 plugins to create virtual networks in Neutron.  OpenVSwitch remains our default and best-supported option.  Note: you cannot use GRE tunnels with the LinuxBridge driver; you'll need to use VXLAN tunnels instead.  And by default, the profile allocates 1 GRE tunnel -- so you must change that immediately, or you will see an error.")
pc.defineParameter("extraImageURLs","Extra VM Image URLs",
                   portal.ParameterType.STRING,"",
                   longDescription="This parameter allows you to specify a space-separated list of URLs, each of which points to an OpenStack VM image, which we will download and slighty tweak before uploading to Glance in your OpenStack experiment.")
pc.defineParameter("firewall","Experiment Firewall",
                   portal.ParameterType.BOOLEAN,False,
                   longDescription="Optionally add a CloudLab infrastructure firewall between the public IP addresses of your nodes (and your floating IPs) and the Internet (and rest of CloudLab).")

pc.defineParameter("ubuntuMirrorHost","Ubuntu Package Mirror Hostname",
                   portal.ParameterType.STRING,"",advanced=True,
                   longDescription="A specific Ubuntu package mirror host to use instead of us.archive.ubuntu.com (mirror must have Ubuntu in top-level dir, or you must also edit the mirror path parameter below)")
pc.defineParameter("ubuntuMirrorPath","Ubuntu Package Mirror Path",
                   portal.ParameterType.STRING,"",advanced=True,
                   longDescription="A specific Ubuntu package mirror path to use instead of /ubuntu/ (you must also set a value for the package mirror parameter)")
pc.defineParameter("doAptUpgrade","Upgrade OpenStack packages and dependencies to the latest versions",
                   portal.ParameterType.BOOLEAN, False,advanced=True,
                   longDescription="The default images this profile uses have OpenStack and dependent packages preloaded.  To guarantee that these scripts always work, we no longer upgrade to the latest packages by default, to avoid changes.  If you want to ensure you have the latest packages, you should enable this option -- but if there are setup failures, we can't guarantee support.  NOTE: selecting this option requires that you also select the option to update the Apt package cache!")
pc.defineParameter("doAptDistUpgrade","Upgrade all packages to their latest versions",
                   portal.ParameterType.BOOLEAN, False,advanced=True,
                   longDescription="Sometimes, if you install using the fromScratch option, you'll need to update some of the base distro packages via apt-get dist-upgrade; this option handles that.  NOTE: selecting this option requires that you also select the option to update the Apt package cache!")
pc.defineParameter("doCloudArchiveStaging","Enable Ubuntu Cloud Archive staging repo",
                   portal.ParameterType.BOOLEAN, False,advanced=True,
                   longDescription="If the base Ubuntu version is an LTS release, we enable package installation from the Ubuntu Cloud Archive.  If you want the latest packages, you must enable the staging repository.  This option does that.  Of course, it only matters if you have selected either a fromScratch install, or if you have selected the option to upgrade installed packages.")
pc.defineParameter("doAptInstall","Install required OpenStack packages and dependencies",
                   portal.ParameterType.BOOLEAN, True,advanced=True,
                   longDescription="This option allows you to tell the setup scripts not to install or upgrade any packages (other than the absolute dependencies without which the scripts cannot run).  If you start from bare images, or select a profile option that may trigger a package to be installed, we may need to install packages for you; and if you have disabled it, we might not be able to configure these features.  This option is really only for people who want to configure only the openstack packages that are already installed on their disk images, and not be surprised by package or database schema upgrades.  NOTE: this option requires that you also select the option to update the Apt package cache!")
pc.defineParameter("doAptUpdate","Update the Apt package cache before installing any packages",
                   portal.ParameterType.BOOLEAN, True,advanced=True,
                   longDescription="This parameter is a bit dangerous.  We update the Apt package cache by default in case we need to install any packages (i.e., if your base image doesn't have OpenStack packages preinstalled, or is missing some package that the scripts must have).  If the cache is outdated, and Apt tries to download a package, that package version may no longer exist on the mirrors.  Only disable this option if you want to minimize the risk that currently-installed pacakges will be upgraded due to dependency pull-in.  Of course, by not updating the package cache, you may not be able to install any packages (and if these scripts need to install packages for you, they may fail!), so be careful with this option.")
pc.defineParameter("fromScratch","Install OpenStack packages on a bare image",
                   portal.ParameterType.BOOLEAN,False,advanced=True,
                   longDescription="If you do not mind waiting awhile for your experiment and OpenStack instance to be available, you can select this option to start from one of our standard Ubuntu disk images; the profile setup scripts will then install all necessary packages.  NOTE: this option may only be used at x86 cluster (i.e., not the \"Utah Cluster\") for now!  NOTE: this option requires that you select both the Apt update and install package options above!")
pc.defineParameter("publicIPCount", "Number of public IP addresses",
                   portal.ParameterType.INTEGER, 4,advanced=True,
                   longDescription="Make sure to include both the number of floating IP addresses you plan to need for instances; and also for OpenVSwitch interface IP addresses.  Each OpenStack network this profile creates for you is bridged to the external, public network, so you also need a public IP address for each of those switch interfaces.  So, if you ask for one GRE tunnel network, and one flat data network (the default configuration), you would need two public IPs for switch interfaces, and then you request two additional public IPs that can be bound to instances as floating IPs.  If you ask for more networks, make sure to increase this number appropriately.")
pc.defineParameter("flatDataLanCount","Number of Flat Data Networks",
                   portal.ParameterType.INTEGER,1,advanced=True,
                   longDescription="Create a number of flat OpenStack networks.  If you do not select the Multiplex Flat Networks option below, each of these networks requires a physical network interface.  If you attempt to instantiate this profile on nodes with only 1 experiment interface, and ask for more than one flat network, your profile will not instantiate correctly.  Many CloudLab nodes have only a single experiment interface.")
pc.defineParameter("greDataLanCount","Number of GRE Tunnel Data Networks",
                   portal.ParameterType.INTEGER,1,advanced=True,
                   longDescription="To use GRE tunnels, you must have at least one flat data network; all tunnels are implemented using the first flat network!")
pc.defineParameter("vlanDataLanCount","Number of VLAN Data Networks",
                   portal.ParameterType.INTEGER,0,advanced=True,
                   longDescription="If you want to play with OpenStack networks that are implemented using real VLAN tags, create VLAN-backed networks with this parameter.  Currently, however, you cannot combine it with Flat nor Tunnel data networks.")
pc.defineParameter("vxlanDataLanCount","Number of VXLAN Data Networks",
                   portal.ParameterType.INTEGER,0,
                   longDescription="To use VXLAN networks, you must have at least one flat data network; all tunnels are implemented using the first flat network!",
                   advanced=True)
pc.defineParameter("useDesignateAsResolver",
                   "Use Designate as physical host nameserver",
                   portal.ParameterType.BOOLEAN,True,
                   longDescription="If using OpenStack Newton or greater, use the Designate nameserver as the primary nameserver for each physical machine.  This will allow you to resolve virtual IPs for instances from the physical machines.",
                   advanced=True)
pc.defineParameter("managementLanType","Management Network Type",
                   portal.ParameterType.STRING,"vpn",[("vpn","VPN"),("flat","Flat")],
                   advanced=True,longDescription="This profile creates a classic OpenStack setup, where services communicate not over the public network, but over an isolated private management network.  By default, that management network is implemented as a VPN hosted on the public network; this allows us to not use up a physical experiment network interface just to host the management network, and leaves that unused interface available for OpenStack data networks.  However, if you are using multiplexed Flat networks, you can also make this a Flat network, and it will be multiplexed along with your other flat networks---isolated by VLAN tags.  These VLAN tags are internal to CloudLab, and are invisible to OpenStack.")

pc.defineParameter("multiplexFlatLans", "Multiplex Flat Networks",
                   portal.ParameterType.BOOLEAN, False,
                   longDescription="Multiplex any flat networks (i.e., management and all of the flat data networks) over physical interfaces, using VLANs.  These VLANs are invisible to OpenStack, unlike the NUmber of VLAN Data Networks option, where OpenStack assigns the real VLAN tags to create its networks.  On CloudLab, many physical machines have only a single experiment network interface, so if you want multiple flat networks, you have to multiplex.  Currently, if you select this option, you *must* specify 0 for VLAN Data Networks; we cannot support both simultaneously yet.",
                   advanced=True)

pc.defineParameter("computeNodeCountSite2", "Number of compute nodes at Site 2",
                   portal.ParameterType.INTEGER, 0,advanced=True,
                   longDescription="You can add additional compute nodes from other CloudLab clusters, allowing you to experiment with remote VMs controlled from the central controller at the first site.")

pc.defineParameter("blockstoreURN", "Remote Block Store URN",
                   portal.ParameterType.STRING, "",advanced=True,
                   longDescription="The URN of a remote block store that already exists that you want attached to the node you specified (defaults to the ctl node).  The block store must exist at the cluster at which you instantiate the profile!")
pc.defineParameter("blockstoreMountNode", "Remote Block Store Mount Node",
                   portal.ParameterType.STRING, "ctl",advanced=True,
                   longDescription="The node on which you want your remote block store mounted; defaults to the controller node.")
pc.defineParameter("blockstoreMountPoint", "Remote Block Store Mount Point",
                   portal.ParameterType.STRING, "/dataset",advanced=True,
                   longDescription="The mount point at which you want your remote block store mounted.  Be careful where you mount it -- something might already be there (i.e., /storage is already taken).  Note also that this option requires a network interface, because it creates a link between the dataset and the node where the dataset is available.  Thus, just as for creating extra LANs, you might need to select the Multiplex Flat Networks option, which will also multiplex the blockstore link here.")
pc.defineParameter("blockstoreReadOnly", "Mount Remote Block Store Read-only",
                   portal.ParameterType.BOOLEAN, True,advanced=True,
                   longDescription="Mount the remote block store in read-only mode.")

pc.defineParameter("localBlockstoreURN", "Local Block Store URN",
                   portal.ParameterType.STRING, "",advanced=True,
                   longDescription="The URN of an image-backed dataset that already exists that you want loaded into the node you specified (defaults to the ctl node).  The block store must exist at the cluster at which you instantiate the profile!")
pc.defineParameter("localBlockstoreMountNode", "Local Block Store Mount Node",
                   portal.ParameterType.STRING, "ctl",advanced=True,
                   longDescription="The node on which you want your local block store mounted; defaults to the controller node.")
pc.defineParameter("localBlockstoreMountPoint", "Local Block Store Mount Point",
                   portal.ParameterType.STRING, "/image-dataset",advanced=True,
                   longDescription="The mount point at which you want your local block store mounted.  Be careful where you mount it -- something might already be there (i.e., /storage is already taken).")
pc.defineParameter("localBlockstoreSize", "Local Block Store Size",
                   portal.ParameterType.INTEGER, 0,advanced=True,
                   longDescription="The necessary space to reserve for your local block store (you should set this to at least the minimum amount of space your image-backed dataset will require).")
pc.defineParameter("localBlockstoreReadOnly", "Mount Local Block Store Read-only",
                   portal.ParameterType.BOOLEAN, True,advanced=True,
                   longDescription="Mount the local block store in read-only mode.")

pc.defineParameter("ipAllocationStrategy","IP Addressing",
                   portal.ParameterType.STRING,"script",[("cloudlab","CloudLab"),("script","This Script")],
                   longDescription="Either let CloudLab auto-generate IP addresses for the nodes in your OpenStack networks, or let this script generate them.  If you include nodes at multiple sites, you must choose this script!  The default is this script, because the subnets CloudLab generates for flat networks are sized according to the number of physical nodes in your topology.  However, when the profile sets up your flat OpenStack networks, it tries to enable your VMs and physical nodes to talk to each other---so they all must be on the same subnet.  Thus, you may not have many IPs left for VMs.  However, if the script IP address generation is buggy or otherwise insufficient, you can fall back to CloudLab and see if that improves things.",
                   advanced=True)

pc.defineParameter("tokenTimeout","Keystone Token Expiration in Seconds",
                   portal.ParameterType.INTEGER,14400,advanced=True,
                   longDescription="Keystone token expiration in seconds.")

pc.defineParameter("sessionTimeout","Horizon Session Timeout in Seconds",
                   portal.ParameterType.INTEGER,14400,advanced=True,
                   longDescription="Horizon session timeout in seconds.")

pc.defineParameter("keystoneVersion","Keystone API Version",
                   portal.ParameterType.INTEGER,
                   0, [ (0,"(default)"),(2,"v2.0"),(3,"v3") ],advanced=True,
                   longDescription="Keystone API Version.  Defaults to v2.0 on Juno and Kilo; defaults to v3 on Liberty and onwards.  You can try to force v2.0 on Liberty and onwards, but we cannot guarantee support for this configuration.")
pc.defineParameter("keystoneUseMemcache","Keystone Uses Memcache",
                   portal.ParameterType.BOOLEAN,False,advanced=True,
                   longDescription="Specify whether or not Keystone should use Memcache as its token backend.  In our testing, this has seemed to exacerbate intermittent Keystone internal errors, so it is off by default, and by default, the SQL token backend is used instead.")
pc.defineParameter("keystoneUseWSGI","Keystone Uses WSGI",
                   portal.ParameterType.INTEGER,
                   2, [ (2,"(default)"),(1,"Yes"),(0,"No") ],advanced=True,
                   longDescription="Specify whether or not Keystone should use Apache/WSGI instead of its own server.  This is the default from Kilo onwards.  In our testing, this has seemed to slow down Keystone.")
pc.defineParameter("quotasOff","Unlimit Default Quotas",
                   portal.ParameterType.BOOLEAN,True,advanced=True,
                   longDescription="Set the default Nova and Cinder quotas to unlimited, at least those that can be set via CLI utils (some cannot be set, but the significant ones can be set).")

pc.defineParameter("disableSecurityGroups","Disable Security Group Enforcement",
                   portal.ParameterType.BOOLEAN,False,advanced=True,
                   longDescription="Sometimes it can be easier to play with OpenStack if you do not have to mess around with security groups at all.  This option selects a null security group driver, if set.  This means security groups are enabled, but are not enforced (we set the firewall_driver neutron option to neutron.agent.firewall.NoopFirewallDriver to accomplish this).")

pc.defineParameter("enableInboundSshAndIcmp","Enable Inbound SSH and ICMP",
                   portal.ParameterType.BOOLEAN,True,advanced=True,
                   longDescription="Enable inbound SSH and ICMP into your instances in the default security group, if you have security groups enabled.")

pc.defineParameter("enableNewSerialSupport","Enable new Juno serial consoles",
                   portal.ParameterType.BOOLEAN,False,advanced=True,
                   longDescription="Enable new serial console support added in Juno.  This means you can access serial consoles via web sockets from a CLI tool (not in the dashboard yet), but the serial console log will no longer be available for viewing!  Until it supports both interactivity and logging, you will have to choose.  We download software for you and create a simple frontend script on your controller node, /root/setup/novaconsole.sh , that when given the name of an instance as its sole argument, will connect you to its serial console.  The escape sequence is ~. (tilde,period), but make sure to use multiple tildes to escape through your ssh connection(s), so that those are not disconnected along with your console session.")

pc.defineParameter("ceilometerUseMongoDB","Use MongoDB in Ceilometer",
                   portal.ParameterType.BOOLEAN,False,advanced=True,
                   longDescription="Use MongoDB for Ceilometer instead of MySQL (with Ubuntu 14 and Juno, we have observed crashy behavior with MongoDB, so the default is MySQL; YMMV.  Also, this option only applies to OpenStack releases < Ocata.")

pc.defineParameter("enableVerboseLogging","Enable Verbose Logging",
                   portal.ParameterType.BOOLEAN,False,advanced=True,
                   longDescription="Enable verbose logging for OpenStack components.")
pc.defineParameter("enableDebugLogging","Enable Debug Logging",
                   portal.ParameterType.BOOLEAN,False,advanced=True,
                   longDescription="Enable debug logging for OpenStack components.")

pc.defineParameter("controllerHost", "Name of controller node",
                   portal.ParameterType.STRING, "ctl", advanced=True,
                   longDescription="The short name of the controller node.  You shold leave this alone unless you really want the hostname to change.")
pc.defineParameter("networkManagerHost", "Name of network manager node",
                   portal.ParameterType.STRING, "ctl",advanced=True,
                   longDescription="The short name of the network manager (neutron) node.  If you specify the same name here as you did for the controller, then your controller and network manager will be unified into a single node.  You shold leave this alone unless you really want the hostname to change.")
pc.defineParameter("computeHostBaseName", "Base name of compute node(s)",
                   portal.ParameterType.STRING, "cp", advanced=True,
                   longDescription="The base string of the short name of the compute nodes (node names will look like cp-1, cp-2, ... or cp-s2-1, cp-s2-2, ... (for nodes at Site 2, if you request those)).  You shold leave this alone unless you really want the hostname to change.")
pc.defineParameter("firewallStyle","Firewall Style",
                   portal.ParameterType.STRING,"none",
                   [("none","None"),("basic","Basic"),("closed","Closed")],
                   advanced=True,
                   longDescription="Optionally add a CloudLab infrastructure firewall between the public IP addresses of your nodes (and your floating IPs) and the Internet (and rest of CloudLab).  The choice you make for this parameter controls the firewall ruleset, if not None.  None means no firewall; Basic implies a simple firewall that allows inbound SSH and outbound HTTP/HTTPS traffic; Closed implies a firewall ruleset that allows *no* communication with the outside world or other experiments within CloudLab.  If you are unsure, the Basic style is the one that will work best for you.")
#pc.defineParameter("blockStorageHost", "Name of block storage server node",
#                   portal.ParameterType.STRING, "ctl")
#pc.defineParameter("objectStorageHost", "Name of object storage server node",
#                   portal.ParameterType.STRING, "ctl")
#pc.defineParameter("blockStorageNodeCount", "Number of block storage nodes",
#                   portal.ParameterType.INTEGER, 0)
#pc.defineParameter("objectStorageNodeCount", "Number of object storage nodes",
#                   portal.ParameterType.STRING, 0)
###pc.defineParameter("adminPass","The OpenStack admin password",
###                   portal.ParameterType.STRING,"",advanced=True,
###                   longDescription="You should choose a unique password at least 8 characters long, with uppercase and lowercase characters, numbers, and special characters.  CAREFULLY NOTE this password; but if you forget, you can find it later on the experiment status page.  If you don't provide a password, it will be randomly generated, and you can find it on your experiment status page after you instantiate the profile.")

#
# Get any input parameter values that will override our defaults.
#
params = pc.bindParameters()

#
# Verify our parameters and throw errors.
#
###
### XXX: get rid of custom root password support for now
###
###if len(params.adminPass) > 0:
###    pwel = []
###    up = low = num = none = total = 0
###    for ch in params.adminPass:
###        if ch.isupper(): up += 1
###        if ch.islower(): low += 1
###        if ch.isdigit(): num += 1
###        if not ch.isalpha(): none += 1
###        total += 1
###        pass
###    if total < 8:
###        pwel.append("Your password should be at least 8 characters in length!")
###    if up == 0 or low == 0 or num == 0 or none == 0:
###        pwel.append("Your password should contain a mix of lowercase, uppercase, digits, and non-alphanumeric characters!")
###    if params.adminPass == "N!ceD3m0":
###        pwel.append("This password cannot be used.")
###    for err in pwel:
###        pc.reportError(portal.ParameterError(err,['adminPass']))
###        pass
###    pass
###elif False:
####    pc.reportError(portal.ParameterError("You cannot set a null password!",
####                                         ['adminPass']))
###    # Generate a random password that conforms to the above requirements.
###    # We only generate passwds with easy nonalpha chars, but we accept any
###    # nonalpha char to satisfy the requirements...
###    nonalphaChars = [33,35,36,37,38,40,41,42,43,64,94]
###    upperChars = range(65,90)
###    lowerChars = range(97,122)
###    decChars = range(48,57)
###    random.shuffle(nonalphaChars)
###    random.shuffle(upperChars)
###    random.shuffle(lowerChars)
###    random.shuffle(decChars)
    
###    passwdList = [nonalphaChars[0],nonalphaChars[1],upperChars[0],upperChars[1],
###                  lowerChars[0],lowerChars[1],decChars[0],decChars[1]]
###    random.shuffle(passwdList)
###    params.adminPass = ''
###    for i in passwdList:
###        params.adminPass += chr(i)
###        pass
###    pass
###else:
###    #
###    # For now, let Cloudlab generate the random password for us; this will
###    # eventually change to the above code.
###    #
###    pass

# Just set the firewall style to something sane if they want a firewall.
if params.firewall == True and params.firewallStyle == 'none':
    params.firewallStyle = 'basic'

if params.controllerHost == params.networkManagerHost \
  and params.release in [ 'juno','kilo' ]:
    perr = portal.ParameterWarning("We do not support use of the same physical node as both controller and networkmanager for older Juno and Kilo releases of this profile.  You can try it, but it may not work.  To revert to the old behavior, open the Advanced Parameters and change the networkManagerHost parameter to nm .",['release','controllerHost','networkManagerHost'])
    pc.reportWarning(perr)
    pass
if params.release in [ 'juno','kilo','liberty' ] \
  and (not params.firewall or params.firewallStyle == 'none'):
    perr = portal.ParameterError("To use deprecated OpenStack releases, you *must* place your nodes behind an infrastructure firewall, by enabling the Firewall parameter.  These releases rely on insecure, out-of-date software.",['release','firewall'])
    pc.reportError(perr)
    pass
if params.ml2plugin == 'linuxbridge' \
  and params.release in [ 'juno','kilo' ]:
    perr = portal.ParameterError("Kilo and Juno do not support the linuxbridge Neutron ML2 driver!",['release','ml2plugin'])
    pc.reportError(perr)
    pass
if params.ml2plugin == 'linuxbridge' and params.greDataLanCount > 0:
    perr = portal.ParameterError("The Neutron ML2 linuxbridge driver does not support GRE tunnel networks.  You should add VXLAN tunnels instead.",['greDataLanCount','ml2plugin','vxlanDataLanCount'])
    pc.reportError(perr)
    pass
if params.release in [ 'juno','kilo' ]:
    perr = portal.ParameterWarning("The %s release is deprecated in this profile; you can use it for now, but it will be removed or refactored in the next version of this profile!",['release'])
    pc.reportWarning(perr)
    pass
if params.computeNodeCount > 8:
    perr = portal.ParameterWarning("Are you creating a real cloud?  Otherwise, do you really need more than 8 compute nodes?  Think of your fellow users scrambling to get nodes :).",['computeNodeCount'])
    pc.reportWarning(perr)
    pass
if params.computeNodeCountSite2 > 8:
    perr = portal.ParameterWarning("Are you creating a real cloud?  Otherwise, do you really need more than 8 compute nodes?  Think of your fellow users scrambling to get nodes :).",['computeNodeCountSite2'])
    pc.reportWarning(perr)
    pass
if params.computeNodeCountSite2 > 0 and not params.multiplexFlatLans:
    perr = portal.ParameterError("If you request nodes at Site 2, you must enable multiplexing for flat lans!",['computeNodeCountSite2','multiplexFlatLans'])
    pc.reportError(perr)
    pass

if params.fromScratch and not params.doAptInstall:
    perr = portal.ParameterError("You cannot start from a bare image and choose not to install any OpenStack packages!",['fromScratch','doAptInstall'])
    pc.reportError(perr)
    pass
if params.doAptUpgrade and not params.doAptInstall:
    perr = portal.ParameterWarning("If you disable package installation, and request package upgrades, nothing will happen; you'll have to comb through the setup script logfiles to see what packages would have been upgraded.",['doAptUpgrade','doAptInstall'])
    pc.reportWarning(perr)
    pass
if params.doAptDistUpgrade and not params.doAptInstall:
    perr = portal.ParameterWarning("If you disable package installation, and request all packages to be upgraded, nothing will happen; so you need to change your parameter values.",['doAptDistUpgrade','doAptInstall'])
    pc.reportWarning(perr)
    pass

if params.publicIPCount > 16:
    perr = portal.ParameterError("You cannot request more than 16 public IP addresses, at least not without creating your own modified version of this profile!",['publicIPCount'])
    pc.reportError(perr)
    pass
if (params.vlanDataLanCount + params.vxlanDataLanCount \
    + params.greDataLanCount + params.flatDataLanCount) \
    > (params.publicIPCount - 1):
    perr = portal.ParameterWarning("You did not request enough public IPs to cover all your data networks and still leave you at least one floating IP; you may want to read this parameter's help documentation and change your parameters!",['publicIPCount'])
    pc.reportWarning(perr)
    pass

if params.vlanDataLanCount > 0 and params.flatDataLanCount > 0:
    perr = portal.ParameterError("You cannot specify vlanDataLanCount > 0 and flatDataLanCount > 0",['vlanDataLanCount','flatDataLanCount'])
    pc.reportError(perr)
    pass
if params.vlanDataLanCount > 0 and params.greDataLanCount > 0:
    perr = portal.ParameterError("You cannot specify vlanDataLanCount > 0 and greDataLanCount > 0",['vlanDataLanCount','greDataLanCount'])
    pc.reportError(perr)
    pass

if params.greDataLanCount > 0 and params.flatDataLanCount < 1:
    perr = portal.ParameterError("You must specifiy at least one flat data network to request one or more GRE data networks!",['greDataLanCount','flatDataLanCount'])
    pc.reportError(perr)
    pass
if params.vxlanDataLanCount > 0 and params.flatDataLanCount < 1:
    perr = portal.ParameterError("You must specifiy at least one flat data network to request one or more VXLAN data networks!",['vxlanDataLanCount','flatDataLanCount'])
    pc.reportError(perr)
    pass

if params.computeNodeCountSite2 > 0 and params.ipAllocationStrategy != "script":
    # or params.computeNodeCountSite3 > 0)
    badpl = ['ipAllocationStrategy']
    if params.computeNodeCountSite2 > 0:
        badpl.append('computeNodeCountSite2')
#    if params.computeNodeCountSite3 > 0:
#        badpl.append('computeNodeCountSite3')
    perr = portal.ParameterError("You must choose an ipAllocationStrategy of 'script' when including compute nodes at multiple sites!",
                                   badpl)
    pc.reportError(perr)
    params.ipAllocationStrategy = "script"
    pass

if params.ipAllocationStrategy == 'script':
    generateIPs = True
else:
    generateIPs = False
    pass

#
# Give the library a chance to return nice JSON-formatted exception(s) and/or
# warnings; this might sys.exit().
#
pc.verifyParameters()

detailedParamAutoDocs = ''
for param in pc._parameterOrder:
    if not pc._parameters.has_key(param):
        continue
    detailedParamAutoDocs += \
      """
  - *%s*

    %s
    (default value: *%s*)
      """ % (pc._parameters[param]['description'],pc._parameters[param]['longDescription'],pc._parameters[param]['defaultValue'])
    pass

tourDescription = \
  "This profile provides a highly-configurable OpenStack instance with a controller and one or more compute nodes (potentially at multiple Cloudlab sites) (and optionally a network manager node, in a split configuration). This profile runs x86 or ARM64 nodes. It sets up OpenStack Pike, Ocata, Newton, or Mitaka on Ubuntu 16.04 (Liberty on 15.10, Kilo on 15.04, and Juno on 14.10 are *deprecated*) according to your choice, and configures all OpenStack services, pulls in some VM disk images, and creates basic networks accessible via floating IPs.  You'll be able to create instances and access them over the Internet in just a few minutes. When you click the Instantiate button, you'll be presented with a list of parameters that you can change to control what your OpenStack instance will look like; **carefully** read the parameter documentation on that page (or in the Instructions) to understand the various features available to you."

###if not params.adminPass or len(params.adminPass) == 0:
passwdHelp = "Your OpenStack admin and instance VM password is randomly-generated by Cloudlab, and it is: `{password-adminPass}` ."
###else:
###    passwdHelp = "Your OpenStack dashboard and instance VM password is `the one you specified in parameter selection`; hopefully you memorized or memoized it!"
###    pass
passwdHelp += "  When logging in to the Dashboard, use the `admin` user; when logging into instance VMs, use the `ubuntu` user.  If you have selected Mitaka or newer, use 'default' as the Domain at the login prompt."

tourInstructions = \
  """
### Basic Instructions
Once your experiment nodes have booted, and this profile's configuration scripts have finished configuring OpenStack inside your experiment, you'll be able to visit [the OpenStack Dashboard WWW interface](http://{host-%s}/horizon/auth/login/?next=/horizon/project/instances/) (approx. 5-15 minutes).  If you've selected the Pike release (or newer), you can also login to [your experiment's Grafana WWW interface](http://{host-%s}:3000/dashboard/db/openstack-instance-statistics) and view OpenStack instance VM statistics once you've created some VMs.  %s

Please wait to login to the OpenStack dashboard until the setup scripts have completed (we've seen Dashboard issues with content not appearing if you login before configuration is complete).  There are multiple ways to determine if the scripts have finished:
  - First, you can watch the experiment status page: the overall State will say \"booted (startup services are still running)\" to indicate that the nodes have booted up, but the setup scripts are still running.
  - Second, the Topology View will show you, for each node, the status of the startup command on each node (the startup command kicks off the setup scripts on each node).  Once the startup command has finished on each node, the overall State field will change to \"ready\".  If any of the startup scripts fail, you can mouse over the failed node in the topology viewer for the status code.
  - Finally, the profile configuration scripts also send you two emails: once to notify you that controller setup has started, and a second to notify you that setup has completed.  Once you receive the second email, you can login to the Openstack Dashboard and begin your work.

**NOTE:** If the web interface rejects your password or gives another error, the scripts might simply need more time to set up the backend. Wait a few minutes and try again.  If you don't receive any email notifications, you can SSH to the 'ctl' node, become root, and check the primary setup script's logfile (/root/setup/setup-controller.log).  If near the bottom there's a line that includes 'Your OpenStack instance has completed setup'), the scripts have finished, and it's safe to login to the Dashboard.

If you need to run the OpenStack CLI tools, or your own scripts that use the OpenStack APIs, you'll find authentication credentials in /root/setup/admin-openrc.sh .  Be aware that the username in this file is `adminapi`, not `admin`; this is an artifact of the days when the profile used to allow you to customize the admin password (it was necessary because the nodes did not have the plaintext password, but only the hash).

*Do not* add any VMs on the `ext-net` network; instead, give them floating IP addresses from the pool this profile requests on your behalf (and increase the size of that pool when you instantiate by changing the `Number of public IP addresses` parameter).  If you try to use any public IP addresses on the `ext-net` network that are not part of your experiment (i.e., any that are not either the control network public IPs for the physical machines, or the public IPs used as floating IPs), those packets will be blocked, and you will be confused.

The profile's setup scripts are automatically installed on each node in `/tmp/setup` .  They execute as `root`, and keep state and downloaded files in `/root/setup/`.  More importantly, they write copious logfiles in that directory; so if you think there's a problem with the configuration, you could take a quick look through these logs --- especially `setup-controller.log` on the `ctl` node.


### Detailed Parameter Documentation
%s
""" % (params.controllerHost,params.controllerHost,passwdHelp,detailedParamAutoDocs)

#
# Setup the Tour info with the above description and instructions.
#  
tour = IG.Tour()
tour.Description(IG.Tour.TEXT,tourDescription)
tour.Instructions(IG.Tour.MARKDOWN,tourInstructions)
rspec.addTour(tour)

#
# Ok, get down to business -- we are going to create CloudLab LANs to be used as
# (openstack networks), based on user's parameters.  We might also generate IP
# addresses for the nodes, so set up some quick, brutally stupid IP address
# generation for each LAN.
#
flatlanstrs = {}
vlanstrs = {}
ipdb = {}
if params.managementLanType == 'flat':
    ipdb['mgmt-lan'] = { 'base':'192.168','netmask':'255.255.0.0','values':[-1,-1,0,0] }
    pass
dataOffset = 10
ipSubnetsUsed = 0
for i in range(1,params.flatDataLanCount + 1):
    dlanstr = "%s-%d" % ('flat-lan',i)
    ipdb[dlanstr] = { 'base' : '10.%d' % (i + dataOffset + ipSubnetsUsed,),'netmask' : '255.255.0.0',
                      'values' : [-1,-1,10,0] }
    flatlanstrs[i] = dlanstr
    ipSubnetsUsed += 1
    pass
for i in range(1,params.vlanDataLanCount + 1):
    dlanstr = "%s-%d" % ('vlan-lan',i)
    ipdb[dlanstr] = { 'base' : '10.%d' % (i + dataOffset + ipSubnetsUsed,),'netmask' : '255.255.0.0',
                      'values' : [-1,-1,10,0] }
    vlanstrs[i] = dlanstr
    ipSubnetsUsed += 1
    pass
for i in range(1,params.vxlanDataLanCount + 1):
    dlanstr = "%s-%d" % ('vxlan-lan',i)
    ipdb[dlanstr] = { 'base' : '10.%d' % (i + dataOffset + ipSubnetsUsed,),'netmask' : '255.255.0.0',
                      'values' : [-1,-1,10,0] }
    ipSubnetsUsed += 1
    pass

# Assume a /16 for every network
def get_next_ipaddr(lan):
    ipaddr = ipdb[lan]['base']
    backpart = ''

    idxlist = range(1,4)
    idxlist.reverse()
    didinc = False
    for i in idxlist:
        if ipdb[lan]['values'][i] is -1:
            break
        if not didinc:
            didinc = True
            ipdb[lan]['values'][i] += 1
            if ipdb[lan]['values'][i] > 254:
                if ipdb[lan]['values'][i-1] is -1:
                    return ''
                else:
                    ipdb[lan]['values'][i-1] += 1
                    pass
                pass
            pass
        backpart = '.' + str(ipdb[lan]['values'][i]) + backpart
        pass

    return ipaddr + backpart

def get_netmask(lan):
    return ipdb[lan]['netmask']

#
# Ok, actually build the data LANs now...
#
flatlans = {}
vlans = {}
alllans = []

for i in range(1,params.flatDataLanCount + 1):
    datalan = RSpec.LAN(flatlanstrs[i])
    if params.osLinkSpeed > 0:
        datalan.bandwidth = int(params.osLinkSpeed)
        pass
    if params.multiplexFlatLans:
        datalan.link_multiplexing = True
        datalan.best_effort = True
        # Need this cause LAN() sets the link type to lan, not sure why.
        datalan.type = "vlan"
        pass
    flatlans[i] = datalan
    alllans.append(datalan)
    pass
for i in range(1,params.vlanDataLanCount + 1):
    datalan = RSpec.LAN("vlan-lan-%d" % (i,))
    if params.osLinkSpeed > 0:
        datalan.bandwidth = int(params.osLinkSpeed)
        pass
    datalan.link_multiplexing = True
    datalan.best_effort = True
    # Need this cause LAN() sets the link type to lan, not sure why.
    datalan.type = "vlan"
    vlans[i] = datalan
    alllans.append(datalan)
    pass

#
# Ok, also build a management LAN if requested.  If we build one, it runs over
# a dedicated experiment interface, not the Cloudlab public control network.
#
if params.managementLanType == 'flat':
    mgmtlan = RSpec.LAN('mgmt-lan')
    if params.multiplexFlatLans:
        mgmtlan.link_multiplexing = True
        mgmtlan.best_effort = True
        # Need this cause LAN() sets the link type to lan, not sure why.
        mgmtlan.type = "vlan"
        pass
    pass
else:
    mgmtlan = None
    pass

#
# Construct the disk image URNs we're going to set the various nodes to load.
#
image_project = 'emulab-ops'
image_urn = 'utah.cloudlab.us'
image_tag_rel = ''
if params.release == "juno":
    image_os = 'UBUNTU14-10-64'
elif params.release == "kilo":
    image_os = 'UBUNTU15-04-64'
elif params.release == 'liberty':
    image_os = 'UBUNTU15-10-64'
elif params.release == 'mitaka':
    image_os = 'UBUNTU16-64'
elif params.release == 'newton':
    image_os = 'UBUNTU16-64'
    image_tag_rel = '-N'
elif params.release == 'ocata':
    image_os = 'UBUNTU16-64'
    image_tag_rel = '-O'
elif params.release == 'pike':
    image_os = 'UBUNTU16-64'
    image_tag_rel = '-P'
else:
    image_os = 'UBUNTU16-64'
    params.fromScratch = True
    params.doAptDistUpgrade = True
    params.doAptUpdate = True
    pass

if params.fromScratch:
    image_tag_cn = 'STD'
    image_tag_nm = 'STD'
    image_tag_cp = 'STD'
    image_tag_rel = ''
else:
    image_tag_cn = 'OSCN'
    image_tag_nm = 'OSNM'
    image_tag_cp = 'OSCP'
    pass

nodes = dict({})

fwrules = [
    # Protogeni xmlrpc
    "iptables -A INSIDE -p tcp --dport 12369 -j ACCEPT",
    "iptables -A INSIDE -p tcp --dport 12370 -j ACCEPT",
    # Inbound http to the controller node.
    "iptables -A OUTSIDE -p tcp -d ctl.EMULAB_EXPDOMAIN --dport 80 -j ACCEPT",
    # Inbound VNC to any host (only need for compute hosts, but hard to
    # specify that).
    "iptables -A OUTSIDE -p tcp --dport 6080 -j ACCEPT",
]

# Firewall node, Site 1.
firewalling = False
setfwdesire = True
if params.firewallStyle in ('open','closed','basic'):
    firewalling = True
    fw = rspec.ExperimentFirewall('fw',params.firewallStyle)
    fw.disk_image = 'urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU16-64-STD'
    fw.Site("1")
    if params.osNodeType:
        fw.hardware_type = params.osNodeType
    for rule in fwrules:
        fw.addRule(rule)
if params.computeNodeCountSite2 > 0:
    # Firewall node, Site 2.
    if params.firewallStyle in ('open','closed','basic'):
        fw2 = rspec.ExperimentFirewall('fw-s2',params.firewallStyle)
        fw2.disk_image = 'urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU16-64-STD'
        fw2.Site("2")
        for rule in fwrules:
            fw2.addRule(rule)
    pass

#
# Add the controller node.
#
controller = RSpec.RawPC(params.controllerHost)
nodes[params.controllerHost] = controller
if params.osNodeType:
    controller.hardware_type = params.osNodeType
    pass
controller.Site("1")
controller.disk_image = "urn:publicid:IDN+%s+image+%s//%s-%s%s" % (image_urn,image_project,image_os,image_tag_cn,image_tag_rel)
if firewalling and setfwdesire:
    controller.Desire('firewallable','1.0')
i = 0
for datalan in alllans:
    iface = controller.addInterface("if%d" % (i,))
    datalan.addInterface(iface)
    if generateIPs:
        iface.addAddress(RSpec.IPv4Address(get_next_ipaddr(datalan.client_id),
                                           get_netmask(datalan.client_id)))
        pass
    i += 1
    pass
if mgmtlan:
    iface = controller.addInterface("ifM")
    mgmtlan.addInterface(iface)
    if generateIPs:
        iface.addAddress(RSpec.IPv4Address(get_next_ipaddr(mgmtlan.client_id),
                                           get_netmask(mgmtlan.client_id)))
        pass
    pass
if TBURL is not None:
    controller.addService(RSpec.Install(url=TBURL, path="/tmp"))
controller.addService(RSpec.Execute(shell="sh",command=TBCMD))
if disableTestbedRootKeys:
    controller.installRootKeys(False, False)

if params.controllerHost != params.networkManagerHost:
    #
    # Add the network manager (neutron) node.
    #
    networkManager = RSpec.RawPC(params.networkManagerHost)
    nodes[params.networkManagerHost] = networkManager
    if params.osNodeType:
        networkManager.hardware_type = params.osNodeType
        pass
    networkManager.Site("1")
    networkManager.disk_image = "urn:publicid:IDN+%s+image+%s//%s-%s%s" % (image_urn,image_project,image_os,image_tag_nm,image_tag_rel)
    if firewalling and setfwdesire:
        networkManager.Desire('firewallable','1.0')
    i = 0
    for datalan in alllans:
        iface = networkManager.addInterface("if%d" % (i,))
        datalan.addInterface(iface)
        if generateIPs:
            iface.addAddress(
                RSpec.IPv4Address(get_next_ipaddr(datalan.client_id),
                                  get_netmask(datalan.client_id)))
            pass
        i += 1
        pass
    if mgmtlan:
        iface = networkManager.addInterface("ifM")
        mgmtlan.addInterface(iface)
        if generateIPs:
            iface.addAddress(
                RSpec.IPv4Address(get_next_ipaddr(mgmtlan.client_id),
                                  get_netmask(mgmtlan.client_id)))
            pass
        pass
    if TBURL is not None:
        networkManager.addService(RSpec.Install(url=TBURL, path="/tmp"))
    networkManager.addService(RSpec.Execute(shell="sh",command=TBCMD))
    if disableTestbedRootKeys:
        networkManager.installRootKeys(False, False)
    pass

#
# Add the compute nodes.  First we generate names for each node at each site;
# then we create those nodes at each site.
#
computeNodeNamesBySite = {}
computeNodeList = ""
for i in range(1,params.computeNodeCount + 1):
    cpname = "%s-%d" % (params.computeHostBaseName,i)
    if not computeNodeNamesBySite.has_key(1):
        computeNodeNamesBySite[1] = []
        pass
    computeNodeNamesBySite[1].append(cpname)
    pass
for i in range(1,params.computeNodeCountSite2 + 1):
    cpname = "%s-s2-%d" % (params.computeHostBaseName,i)
    if not computeNodeNamesBySite.has_key(2):
        computeNodeNamesBySite[2] = []
        pass
    computeNodeNamesBySite[2].append(cpname)
    pass

for (siteNumber,cpnameList) in computeNodeNamesBySite.iteritems():
    for cpname in cpnameList:
        cpnode = RSpec.RawPC(cpname)
        nodes[cpname] = cpnode
        if params.osNodeType:
            cpnode.hardware_type = params.osNodeType
        pass
        cpnode.Site(str(siteNumber))
        cpnode.disk_image = "urn:publicid:IDN+%s+image+%s//%s-%s%s" % (image_urn,image_project,image_os,image_tag_cp,image_tag_rel)
        if firewalling and setfwdesire:
            cpnode.Desire('firewallable','1.0')
        i = 0
        for datalan in alllans:
            iface = cpnode.addInterface("if%d" % (i,))
            datalan.addInterface(iface)
            if generateIPs:
                iface.addAddress(RSpec.IPv4Address(get_next_ipaddr(datalan.client_id),
                                                   get_netmask(datalan.client_id)))
                pass
            i += 1
            pass
        if mgmtlan:
            iface = cpnode.addInterface("ifM")
            mgmtlan.addInterface(iface)
            if generateIPs:
                iface.addAddress(RSpec.IPv4Address(get_next_ipaddr(mgmtlan.client_id),
                                                   get_netmask(mgmtlan.client_id)))
                pass
            pass
        if TBURL is not None:
            cpnode.addService(RSpec.Install(url=TBURL, path="/tmp"))
        cpnode.addService(RSpec.Execute(shell="sh",command=TBCMD))
        if disableTestbedRootKeys:
            cpnode.installRootKeys(False, False)
        computeNodeList += cpname + ' '
        pass
    pass

#
# Add the blockstore, if requested.
#
bsnode = None
bslink = None
if params.blockstoreURN != "":
    if not nodes.has_key(params.blockstoreMountNode):
        #
        # This is a very late time to generate a warning, but that's ok!
        #
        perr = portal.ParameterError("The node on which you mount your block store must exist, and does not!",
                                     ['blockstoreMountNode'])
        pc.reportError(perr)
        pc.verifyParameters()
        pass
    
    rbsn = nodes[params.blockstoreMountNode]
    myintf = rbsn.addInterface("ifbs0")
    
    bsnode = IG.RemoteBlockstore("bsnode",params.blockstoreMountPoint)
    bsnode.Site("1")
    if firewalling and setfwdesire:
        bsnode.Desire('firewallable','1.0')
    bsintf = bsnode.interface
    bsnode.dataset = params.blockstoreURN
    #bsnode.size = params.N
    bsnode.readonly = params.blockstoreReadOnly
    
    bslink = RSpec.Link("bslink")
    bslink.addInterface(myintf)
    bslink.addInterface(bsintf)
    # Special blockstore attributes for this link.
    bslink.best_effort = True
    bslink.vlan_tagging = True
    pass

#
# Add the local blockstore, if requested.
#
lbsnode = None
if params.localBlockstoreURN != "":
    if not nodes.has_key(params.localBlockstoreMountNode):
        #
        # This is a very late time to generate a warning, but that's ok!
        #
        perr = portal.ParameterError("The node on which you mount your local block store must exist, and does not!",
                                     ['localBlockstoreMountNode'])
        pc.reportError(perr)
        pc.verifyParameters()
        pass
    if params.localBlockstoreSize is None or params.localBlockstoreSize <= 0 \
      or str(params.localBlockstoreSize) == "":
        #
        # This is a very late time to generate a warning, but that's ok!
        #
        perr = portal.ParameterError("You must specify a size (> 0) for your local block store!",
                                     ['localBlockstoreSize'])
        pc.reportError(perr)
        pc.verifyParameters()
        pass

    lbsn = nodes[params.localBlockstoreMountNode]
    lbsnode = lbsn.Blockstore("lbsnode",params.localBlockstoreMountPoint)
    lbsnode.dataset = params.localBlockstoreURN
    lbsnode.size = str(params.localBlockstoreSize)
    lbsnode.readonly = params.localBlockstoreReadOnly
    pass

for nname in nodes.keys():
    rspec.addResource(nodes[nname])
if bsnode:
    rspec.addResource(bsnode)
for datalan in alllans:
    rspec.addResource(datalan)
if mgmtlan:
    rspec.addResource(mgmtlan)
if bslink:
    rspec.addResource(bslink)
    pass

#
# Grab a few public IP addresses.
#
apool = IG.AddressPool(params.networkManagerHost,params.publicIPCount)
try:
    apool.Site("1")
except:
    pass
rspec.addResource(apool)

class EmulabEncrypt(RSpec.Resource):
    def _write(self, root):
        ns = "{http://www.protogeni.net/resources/rspec/ext/emulab/1}"

#        el = ET.SubElement(root,"%sencrypt" % (ns,),attrib={'name':'adminPass'})
#        el.text = params.adminPass
        el = ET.SubElement(root,"%spassword" % (ns,),attrib={'name':'adminPass'})
        pass
    pass

#
# Add our parameters to the request so we can get their values to our nodes.
# The nodes download the manifest(s), and the setup scripts read the parameter
# values when they run.
#
class Parameters(RSpec.Resource):
    def _write(self, root):
        ns = "{http://www.protogeni.net/resources/rspec/ext/johnsond/1}"
        paramXML = "%sparameter" % (ns,)
        
        el = ET.SubElement(root,"%sprofile_parameters" % (ns,))

        param = ET.SubElement(el,paramXML)
        param.text = 'CONTROLLER="%s"' % (params.controllerHost,)
        param = ET.SubElement(el,paramXML)
        param.text = 'NETWORKMANAGER="%s"' % (params.networkManagerHost,)
        param = ET.SubElement(el,paramXML)
        param.text = 'COMPUTENODES="%s"' % (computeNodeList,)
#        param = ET.SubElement(el,paramXML)
#        param.text = 'STORAGEHOST="%s"' % (params.blockStorageHost,)
#        param = ET.SubElement(el,paramXML)
#        param.text = 'OBJECTHOST="%s"' % (params.objectStorageHost,)
        param = ET.SubElement(el,paramXML)
        param.text = 'DATALANS="%s"' % (' '.join(map(lambda(lan): lan.client_id,alllans)))
        param = ET.SubElement(el,paramXML)
        param.text = 'DATAFLATLANS="%s"' % (' '.join(map(lambda(i): flatlans[i].client_id,range(1,params.flatDataLanCount + 1))))
        param = ET.SubElement(el,paramXML)
        param.text = 'DATAVLANS="%s"' % (' '.join(map(lambda(i): vlans[i].client_id,range(1,params.vlanDataLanCount + 1))))
        param = ET.SubElement(el,paramXML)
        param.text = 'DATAVXLANS="%d"' % (params.vxlanDataLanCount,)
        param = ET.SubElement(el,paramXML)
        param.text = 'DATATUNNELS=%d' % (params.greDataLanCount,)
        param = ET.SubElement(el,paramXML)
        if mgmtlan:
            param.text = 'MGMTLAN="%s"' % (mgmtlan.client_id,)
        else:
            param.text = 'MGMTLAN=""'
            pass
#        param = ET.SubElement(el,paramXML)
#        param.text = 'STORAGEHOST="%s"' % (params.blockStorageHost,)
        param = ET.SubElement(el,paramXML)
        param.text = 'DO_APT_INSTALL=%d' % (int(params.doAptInstall),)
        param = ET.SubElement(el,paramXML)
        param.text = 'DO_APT_UPGRADE=%d' % (int(params.doAptUpgrade),)
        param = ET.SubElement(el,paramXML)
        param.text = 'DO_APT_DIST_UPGRADE=%d' % (int(params.doAptDistUpgrade),)
        param = ET.SubElement(el,paramXML)
        param.text = 'DO_UBUNTU_CLOUDARCHIVE_STAGING=%d' % (int(params.doCloudArchiveStaging),)
        param = ET.SubElement(el,paramXML)
        param.text = 'DO_APT_UPDATE=%d' % (int(params.doAptUpdate),)

###        if params.adminPass and len(params.adminPass) > 0:
###            random.seed()
###            salt = ""
###            schars = [46,47]
###            schars.extend(range(48,58))
###            schars.extend(range(97,123))
###            schars.extend(range(65,91))
###            for i in random.sample(schars,16):
###                salt += chr(i)
###                pass
###            hpass = crypt.crypt(params.adminPass,'$6$%s' % (salt,))
###            param = ET.SubElement(el,paramXML)
###            param.text = "ADMIN_PASS_HASH='%s'" % (hpass,)
###            pass
###        else:
        param = ET.SubElement(el,paramXML)
        param.text = "ADMIN_PASS_HASH=''"
###            pass
        
        param = ET.SubElement(el,paramXML)
        param.text = "ENABLE_NEW_SERIAL_SUPPORT=%d" % (int(params.enableNewSerialSupport))
        
        param = ET.SubElement(el,paramXML)
        param.text = "DISABLE_SECURITY_GROUPS=%d" % (int(params.disableSecurityGroups))
        
        param = ET.SubElement(el,paramXML)
        param.text = "DEFAULT_SECGROUP_ENABLE_SSH_ICMP=%d" % (int(params.enableInboundSshAndIcmp))
        
        param = ET.SubElement(el,paramXML)
        param.text = "CEILOMETER_USE_MONGODB=%d" % (int(params.ceilometerUseMongoDB))
        
        param = ET.SubElement(el,paramXML)
        param.text = "VERBOSE_LOGGING=\"%s\"" % (str(bool(params.enableVerboseLogging)))
        param = ET.SubElement(el,paramXML)
        param.text = "DEBUG_LOGGING=\"%s\"" % (str(bool(params.enableDebugLogging)))
        
        param = ET.SubElement(el,paramXML)
        param.text = "TOKENTIMEOUT=%d" % (int(params.tokenTimeout))
        param = ET.SubElement(el,paramXML)
        param.text = "SESSIONTIMEOUT=%d" % (int(params.sessionTimeout))
        
        if params.keystoneVersion > 0:
            param = ET.SubElement(el,paramXML)
            param.text = "KEYSTONEAPIVERSION=%d" % (int(params.keystoneVersion))
            pass
        
        param = ET.SubElement(el,paramXML)
        param.text = "KEYSTONEUSEMEMCACHE=%d" % (int(bool(params.keystoneUseMemcache)))
        
        if params.keystoneUseWSGI == 0:
            param = ET.SubElement(el,paramXML)
            param.text = "KEYSTONEUSEWSGI=0"
        elif params.keystoneUseWSGI == 1:
            param = ET.SubElement(el,paramXML)
            param.text = "KEYSTONEUSEWSGI=1"
        else:
            pass
        
        param = ET.SubElement(el,paramXML)
        param.text = "QUOTASOFF=%d" % (int(bool(params.quotasOff)))
        
        if params.ubuntuMirrorHost != "":
            param = ET.SubElement(el,paramXML)
            param.text = "UBUNTUMIRRORHOST=\"%s\"" % (params.ubuntuMirrorHost,)
        if params.ubuntuMirrorPath != "":
            param = ET.SubElement(el,paramXML)
            param.text = "UBUNTUMIRRORPATH=\"%s\"" % (params.ubuntuMirrorPath,)
            pass

        param = ET.SubElement(el,paramXML)
        param.text = "ML2PLUGIN=%s" % (str(params.ml2plugin))

        param = ET.SubElement(el,paramXML)
        param.text = "USE_DESIGNATE_AS_RESOLVER=%d" % (int(bool(params.useDesignateAsResolver)))

        param = ET.SubElement(el,paramXML)
        param.text = "EXTRAIMAGEURLS='%s'" % (str(params.extraImageURLs))

        param = ET.SubElement(el,paramXML)
        param.text = "OSRELEASE='%s'" % (str(params.release))

        return el
    pass

parameters = Parameters()
rspec.addResource(parameters)

###if not params.adminPass or len(params.adminPass) == 0:
if True:
    stuffToEncrypt = EmulabEncrypt()
    rspec.addResource(stuffToEncrypt)
    pass

pc.printRequestRSpec(rspec)
