This is an Openstack profile that is based on CloudLab's [default OpenStack profile](https://gitlab.flux.utah.edu/johnsond/openstack-build-ubuntu)

- These are a collection of scripts that install and configuration
Openstack Juno on Ubuntu 14 and onwards, within an Emulab/Apt/Cloudlab
testbed experiment.

- Modifications will be added to setup-controller.sh to further customize the cloud environment

2018/10/04
This profile is being modified to support the deployment of Docker image. 
The tentative plan is to modify setup-computer.sh to include the installation steps described in https://wiki.openstack.org/wiki/Docker
