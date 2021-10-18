#!/bin/sh
##howto run from CVM:
## curl --remote-name --location https://raw.githubusercontent.com/wolfganghuse/nutanix-cluster-setup/master/setup-cluster.sh && sh ${_##*/}
REPOSITORY=nutanix-cluster-setup
BRANCH=master
ARCHIVE=https://github.com/wolfganghuse/${REPOSITORY}/archive/${BRANCH}.zip

curl --remote-name --location ${ARCHIVE} \
  && echo "Success: ${ARCHIVE##*/}" \
  && unzip ${ARCHIVE##*/}

pushd ${REPOSITORY}-${BRANCH}/scripts \
&& chmod -R u+x *.sh

# Source Nutanix environment (PATH + aliases), then common routines + global variables
. /etc/profile.d/nutanix_env.sh
. lib.common.sh
. lib.pe.sh

ncli=/home/nutanix/prism/cli/ncli
acli=/usr/local/nutanix/bin/acli
#cvm_ips=10.120.100.30,10.120.100.31,10.120.100.32,10.120.100.33
cvm_ips=172.23.2.2
cluster_name=NTNX-Demo
cluster_ip=172.23.1.121
DATA_SERVICE_IP=172.23.1.122
dns_ip=172.23.0.23
ntp_server=time.google.com
timezone=Europe/Berlin
STORAGE_POOL=sp1
STORAGE_DEFAULT=Default
STORAGE_IMAGES=Images
centos_image=CentOS7-Install
autodc_image=AutoDC-2.0
centos_annotation="CentOS7-Installation-ISO"
centos_source=http://iso-store.objects-clu1.ntnx.test/CentOS7-2009.qcow2
autodc_source=http://iso-store.objects-clu1.ntnx.test/autodc-2.0.qcow2
pc_metadata=http://iso-store.objects-clu1.ntnx.test/pc.2021.9-metadata.json
pc_bits=http://iso-store.objects-clu1.ntnx.test/pc.2021.9.tar
NW1_NAME='Primary'
NW1_VLAN=0
NW1_SUBNET="172.23.0.0/16"
NW1_GATEWAY="172.23.0.1"
NW1_DHCP_START="172.23.108.140"
NW1_DHCP_END="172.23.108.140"

centos7_vm_name=CentOS7-VM
centos7_vm_disk_size=20G
PRISM_ADMIN=admin
PE_PASSWORD=nx2Tech100!
PE_DEFAULTPW=Nutanix/4u
CURL_HTTP_OPTS=' --max-time 25 --silent --header Content-Type:application/json --header Accept:application/json  --insecure '
EMAIL=wolfgang@nutanix.com
SMTP_SERVER_ADDRESS=1.1.1.1
SMTP_SERVER_FROM=wolfgang@nutanix.com
SMTP_SERVER_PORT=25
ATTEMPTS=40
SLEEP=60

# discover available nodes
echo Discovering nodes ...
/usr/local/nutanix/cluster/bin/discover_nodes

# create cluster
echo Creating cluster ...
/usr/local/nutanix/cluster/bin/cluster -s $cvm_ips create --redundancy_factor=2

# pause while Prism services restart
echo Pausing for 30s while Prism services start ...
sleep 30s

#pe_init
pe_license \
&& pe_init \
&& network_configure

pc_install "${NW1_NAME}" \
&& prism_check 'PC'

exit 

pause
# rename cluster
echo Setting cluster name, adding cluster external IP address and adding cluster external data services IP address ...
$ncli cluster edit-params new-name="$cluster_name" external-ip-address="$cluster_ip" external-data-services-ip-address="$cluster_ds_ip"

# specify DNS and NTP servers
echo Adding DNS and NTP servers ...
$ncli cluster add-to-name-servers servers="$dns_ip"
$ncli cluster add-to-ntp-servers servers="$ntp_server"

# set cluster timezone
echo Setting cluster time zone ...
$ncli cluster set-timezone timezone=$timezone force=true

# Change default Credential
$ncli user change-password current-password="${PE_DEFAULTPW}" new-password="${PE_PASSWORD}"

# PE Validate/License
_test=$(curl $CURL_HTTP_OPTS --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST --data '{
    "username": "Huse/Automated",
    "companyName": "Nutanix",
    "jobTitle": "SA"
}' https://localhost:9440/PrismGateway/services/rest/v1/eulas/accept)
echo "Validate EULA on PE: _test=|${_test}|"

_test=$(curl $CURL_HTTP_OPTS --user ${PRISM_ADMIN}:${PE_PASSWORD} -X PUT --data '{
    "defaultNutanixEmail": null,
    "emailContactList": null,
    "enable": false,
    "enableDefaultNutanixEmail": false,
    "isPulsePromptNeeded": false,
    "nosVersion": null,
    "remindLater": null,
    "verbosityType": null
}' https://localhost:9440/PrismGateway/services/rest/v1/pulse)
echo "Disable Pulse in PE: _test=|${_test}|"



# rename default storage pool
echo Renaming default storage pool ...
default_sp=$(ncli storagepool ls | grep 'Name' | cut -d ':' -f 2 | sed s/' '//g)
ncli sp edit name="${default_sp}" new-name="${sp_name}"

# rename default container
default_container=$(ncli container ls | grep -P '^(?!.*VStore Name).*Name' | cut -d ':' -f 2 | sed s/' '//g | grep '^default-container-')
ncli container edit name="${default_container}" new-name="${container_name}"

# creating container for storing images
(ncli container ls | grep -P '^(?!.*VStore Name).*Name' \
    | cut -d ':' -f 2 | sed s/' '//g | grep "^${images_container_name}" > /dev/null 2>&1) \
    && log "Container ${images_container_name} exists" \
    || ncli container create name="${images_container_name}" sp-name="${sp_name}"


# create CentOS 7 VM image
echo Creating CentOS 7 image - this can take a while, depending on your internet connection ...
$acli image.create "$centos_image" image_type=kDiskImage container="$images_container_name" annotation="$centos_annotation" source_url="$centos_source"

# create AutoDC VM image
echo Creating AutoDC image - this can take a while, depending on your internet connection ...
$acli image.create "$autodc_image" image_type=kDiskImage container="$images_container_name" annotation="ntnxlab.local AutoDC" source_url="$autodc_source"

# create network
echo Creating $vlan_name network ...
$acli net.create $vlan_name vlan=$vlan_id ip_config=$vlan_ip_config
echo Adding DHCP pool ...
$acli net.add_dhcp_pool $vlan_name start=$dhcp_pool_start end=$dhcp_pool_end
echo Configuring $vlan_name DNS settings ...
$acli net.update_dhcp_dns $vlan_name domains=$domain_name servers=$dns_ip

# create VMs - AutoDC
echo Creating AutoDC ...
$acli vm.create "AutoDC" num_vcpus=2 num_cores_per_vcpu=1 memory=2G
echo Creating system disk ...
$acli vm.disk_create "AutoDC" cdrom=true clone_from_image="$autodc_image"
echo Creating network adapter ...
$acli vm.nic_create "AutoDC" network=$vlan_name
echo Powering on AutoDC ...
$acli vm.on "AutoDC"


# Upload PC-Bits




# create VMs - CentOS 7
#echo Creating CentOS 7 VM ...
#$acli vm.create $centos7_vm_name num_vcpus=1 num_cores_per_vcpu=1 memory=1G
#echo Attaching CDROM device ...
#$acli vm.disk_create $centos7_vm_name cdrom=true clone_from_image="$centos_image"
#echo Creating system disk ...
#$acli vm.disk_create $centos7_vm_name create_size=$centos7_vm_disk_size container="$container_name"
#echo Creating network adapter ...
#$acli vm.nic_create $centos7_vm_name network=$vlan_name
#echo Powering on CentOS 7 VM ...
#$acli vm.on $centos7_vm_name

echo Done!