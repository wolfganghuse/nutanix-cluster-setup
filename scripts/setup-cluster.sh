ncli=/home/nutanix/prism/cli/ncli
cvm_ips="172.23.2.2"
dns_ip="172.23.0.23"
PE_HOST="172.23.1.121"
PE_DEFAULTPW=Nutanix/4u
PE_PASSWORD=nx2Tech100!

# create cluster
echo Creating cluster ...
/usr/local/nutanix/cluster/bin/cluster -s $cvm_ips create --redundancy_factor=2

# pause while Prism services restart
echo Pausing for 30s while Prism services start ...
sleep 30s

# Change default Credential
$ncli user change-password current-password="${PE_DEFAULTPW}" new-password="${PE_PASSWORD}"

$ncli cluster edit-params external-ip-address=$PE_HOST
# specify DNS and NTP servers
echo Adding DNS and NTP servers ...
$ncli cluster add-to-name-servers servers=$dns_ip

exit 
# Additional settings, not needed here

#timezone=Europe/Berlin
#acli=/usr/local/nutanix/bin/acli
#centos_image=CentOS7-Install
#centos_annotation="CentOS7-Installation-ISO"
#centos_source=http://iso-store.objects-clu1.ntnx.test/CentOS7-2009.qcow2
#centos7_vm_name=CentOS7-VM
#centos7_vm_disk_size=20G

#Name, IP-Settings
$ncli cluster edit-params new-name="$cluster_name" external-ip-address="$PE_HOST" external-data-services-ip-address="$DATA_SERVICE_IP"
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