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
source /etc/profile.d/nutanix_env.sh
source /home/nutanix/${REPOSITORY}-${BRANCH}/scripts/global.vars.sh
source /home/nutanix/${REPOSITORY}-${BRANCH}/scripts/lib.common.sh
source /home/nutanix/${REPOSITORY}-${BRANCH}/scripts/lib.pe.sh

# discover available nodes
echo Discovering nodes ...
#/usr/local/nutanix/cluster/bin/discover_nodes

# create cluster
echo Creating cluster ...
/usr/local/nutanix/cluster/bin/cluster -s $cvm_ips create --redundancy_factor=2

# pause while Prism services restart
echo Pausing for 30s while Prism services start ...
sleep 30s

# Change default Credential
$ncli user change-password current-password="${PE_DEFAULTPW}" new-password="${PE_PASSWORD}"

# specify DNS and NTP servers
echo Adding DNS and NTP servers ...
$ncli cluster add-to-name-servers servers="$DNS_SERVERS"

# rename cluster
echo Setting cluster name and adding cluster external IP ipAddresses
$ncli cluster edit-params new-name="$cluster_name" external-ip-address="$PE_HOST"


#pe_init
dependencies 'install' 'sshpass' && dependencies 'install' 'jq' \
pe_license \
&& pe_init \
&& network_configure \
&& authentication_source

pause
pc_install "${NW1_NAME}" \
&& prism_check 'PC'

exit 

pause
# rename cluster
echo Setting cluster name, adding cluster external IP address and adding cluster external data services IP address ...
$ncli cluster edit-params new-name="$cluster_name" external-ip-address="$PE_HOST" external-data-services-ip-address="$DATA_SERVICE_IP"

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