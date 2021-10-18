#!/usr/bin/env bash

# shellcheck disable=SC2034
RELEASE='release.json'
PC_DEV_VERSION='pc.2021.9'
PC_CURRENT_VERSION='pc.2021.9'
PC_STABLE_VERSION='5.19.1'
NTNX_INIT_PASSWORD='Nutanix/4u'
PRISM_ADMIN='admin'
SSH_PUBKEY="${HOME}/.ssh/id_rsa.pub"
STORAGE_POOL='SP01'
STORAGE_DEFAULT='Default'
STORAGE_IMAGES='Images'
ATTEMPTS=40
SLEEP=60

# Curl and SSH settings
CURL_OPTS='--insecure --silent --show-error' # --verbose'
CURL_POST_OPTS="${CURL_OPTS} --max-time 5 --header Content-Type:application/json --header Accept:application/json --output /dev/null"
CURL_HTTP_OPTS="${CURL_POST_OPTS} --write-out %{http_code}"
SSH_OPTS='-o StrictHostKeyChecking=no -o GlobalKnownHostsFile=/dev/null -o UserKnownHostsFile=/dev/null'
SSH_OPTS+=' -q' # -v'

####################################################
# Users for Tools VMs and Source VMs
###################################################

USERS=(\
   User01 \
   User02 \
   User03 \
   User04 \
   User05 \
   User06 \
)


##################################
#
# Look for JQ, AutoDC, and QCOW2 Repos in DC specific below.
#
##################################

_prio_images_arr=(\
  ERA-Server-build-1.2.1.qcow2 \
  Windows2016.qcow2 \
  CentOS7.qcow2 \
  Citrix_Virtual_Apps_and_Desktops_7_1912.iso \
)

QCOW2_IMAGES=(\
   CentOS7.qcow2 \
   Windows2016.qcow2 \
   Windows2012R2.qcow2 \
   Windows10-1709.qcow2 \
   WinToolsVM.qcow2 \
   Linux_ToolsVM.qcow2 \
   ERA-Server-build-1.2.1.qcow2 \
   MSSQL-2016-VM.qcow2 \
   hycu-3.5.0-6253.qcow2 \
   VeeamAvailability_1.0.457.vmdk \
   move3.2.0.qcow2 \
)
ISO_IMAGES=(\
   CentOS7.iso \
   Windows2016.iso \
   Windows2012R2.iso \
   Windows10.iso \
   Nutanix-VirtIO-1.1.5.iso \
   VeeamBR_9.5.4.2615.Update4.iso \
)

# shellcheck disable=2206
OCTET=(${PE_HOST//./ }) # zero index
IPV4_PREFIX=${OCTET[0]}.${OCTET[1]}.${OCTET[2]}
DATA_SERVICE_IP=${IPV4_PREFIX}.$((${OCTET[3]} + 1))
PC_HOST=${IPV4_PREFIX}.$((${OCTET[3]} + 2))
DNS_SERVERS='172.23.0.23'
NTP_SERVERS='0.us.pool.ntp.org,1.us.pool.ntp.org,2.us.pool.ntp.org,3.us.pool.ntp.org'
SUBNET_MASK="255.255.0.0"

# Getting the network ready

NW1_NAME='Primary'
NW1_VLAN=0

NW1_SUBNET="${IPV4_PREFIX}.1/25"
NW1_GATEWAY="${IPV4_PREFIX}.1"
NW1_DHCP_START="${IPV4_PREFIX}.50"
NW1_DHCP_END="${IPV4_PREFIX}.125"

NW2_NAME='Secondary'
NW2_VLAN=$((OCTET[2]*10+1))
NW2_SUBNET="${IPV4_PREFIX}.129/25"
NW2_GATEWAY="${IPV4_PREFIX}.129"
NW2_DHCP_START="${IPV4_PREFIX}.132"
NW2_DHCP_END="${IPV4_PREFIX}.253"

NW3_NAME='EraManaged'
NW3_NETMASK='255.255.255.128'
NW3_START="${IPV4_PREFIX}.220"
NW3_END="${IPV4_PREFIX}.253"

PC_CURRENT_METAURL='http://10.55.251.38/workshop_staging/pcdeploy-pc.2020.9.json'
PC_CURRENT_URL='http://10.55.251.38/workshop_staging/pc.2020.9.tar'

JQ_REPOS=(\
        'https://s3.amazonaws.com/get-ahv-images/jq-linux64.dms' \
        #'https://github.com/stedolan/jq/releases/download/jq-1.5/jq-linux64' \
)
SSHPASS_REPOS=(\
    'http://10.55.251.38/workshop_staging/sshpass-1.06-2.el7.x86_64.rpm' \
    #'http://mirror.centos.org/centos/7/extras/x86_64/Packages/sshpass-1.06-2.el7.x86_64.rpm' \
)
QCOW2_REPOS=(\
    'http://10.55.251.38/workshop_staging/' \
    'https://s3.amazonaws.com/get-ahv-images/' \
)
AUTODC_REPOS=(\
    'http://10.55.251.38/workshop_staging/AutoDC2.qcow2' \
    'https://s3.amazonaws.com/get-ahv-images/AutoDC2.qcow2' \
)
AUTOAD_REPOS=(\
'http://10.55.251.38/workshop_staging/AutoAD.qcow2' \
'https://s3.amazonaws.com/get-ahv-images/AutoAD.qcow2' \
)
PC_DATA='http://10.55.251.38/workshop_staging/seedPC.zip'
BLUEPRINT_URL='http://10.55.251.38/workshop_staging/CalmBlueprints/'
DNS_SERVERS='10.55.251.10,10.55.251.11'
