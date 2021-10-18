#!/usr/bin/env bash
# -x
# Dependencies: acli, ncli, jq, sshpass, curl, md5sum, pgrep, wc, tr, pkill

###############################################################################################################################################################################
# Routine to set the acli command
###############################################################################################################################################################################
function acli() {
  local _cmd

  _cmd=$*
	/usr/local/nutanix/bin/acli ${_cmd}
  # DEBUG=1 && if [[ ${DEBUG} ]]; then log "$@"; fi
}

###############################################################################################################################################################################
# Routine to install the AutoDC and join the Domain
###############################################################################################################################################################################
function authentication_source() {
  local   _attempts
  local      _error=13
  local       _loop
  local _pc_version
  local     _result
  local      _sleep
  local       _test=0
  local         _vm

  args_required 'AUTH_SERVER AUTH_FQDN SLEEP STORAGE_IMAGES PC_VERSION'

  if [[ -z ${AUTH_SERVER} ]]; then
    log "Error ${_error}: please provide a choice for authentication server."
    exit ${_error}
  fi
  # shellcheck disable=2206
  _pc_version=(${PC_VERSION//./ })

  case "${AUTH_SERVER}" in
    'AutoDC')
      local    _autodc_auth
      local   _autodc_index=1
      local _autodc_release=1
      local _autodc_service='samba-ad-dc'
      local _autodc_restart="service ${_autodc_service} restart"
      local  _autodc_status="systemctl show ${_autodc_service} --property=SubState"
      local _autodc_success='SubState=running'

      _autodc_auth=" --username=${AUTH_ADMIN_USER} --password=${AUTH_ADMIN_PASS}"
      _autodc_index=''
      _autodc_release=2
      _autodc_service=samba
      _autodc_restart="sleep 2 && service ${_autodc_service} stop && sleep 5 && service ${_autodc_service} start"
      _autodc_status="service ${_autodc_service} status"
      _autodc_success=' * status: started'
    
      dns_check "dc${_autodc_index}.${AUTH_FQDN}"
      _result=$?

      if (( ${_result} == 0 )); then
        log "${AUTH_SERVER}${_autodc_release}.IDEMPOTENCY: dc${_autodc_index}.${AUTH_FQDN} set, skip. ${_result}"
      else
        log "${AUTH_SERVER}${_autodc_release}.IDEMPOTENCY failed, no DNS record dc${_autodc_index}.${AUTH_FQDN}"

        _error=12
         _loop=0
        _sleep=${SLEEP}

        repo_source AUTODC_REPOS[@]

        if (( $(source /etc/profile.d/nutanix_env.sh && acli image.list | grep ${AUTH_SERVER}${_autodc_release} | wc --lines) == 0 )); then
          log "Import ${AUTH_SERVER}${_autodc_release} image from ${SOURCE_URL}..."
          acli image.create ${AUTH_SERVER}${_autodc_release} \
            image_type=kDiskImage wait=true \
            container=${STORAGE_IMAGES} source_url=${SOURCE_URL}
        else
          log "Image found, assuming ready. Skipping ${AUTH_SERVER}${_autodc_release} import."
        fi

        log "Create ${AUTH_SERVER}${_autodc_release} VM based on ${AUTH_SERVER}${_autodc_release} image"
        acli "vm.create ${AUTH_SERVER}${_autodc_release} num_vcpus=2 num_cores_per_vcpu=1 memory=2G"
        # vmstat --wide --unit M --active # suggests 2G sufficient, was 4G
        #acli "vm.disk_create ${AUTH_SERVER}${_autodc_release} cdrom=true empty=true"
        acli "vm.disk_create ${AUTH_SERVER}${_autodc_release} clone_from_image=${AUTH_SERVER}${_autodc_release}"
        acli "vm.nic_create ${AUTH_SERVER}${_autodc_release} network=${NW1_NAME} ip=${AUTH_HOST}"

        log "Power on ${AUTH_SERVER}${_autodc_release} VM..."
        acli "vm.on ${AUTH_SERVER}${_autodc_release}"

        _attempts=20
            _loop=0
           _sleep=10

        while true ; do
          (( _loop++ ))

          _test=$(remote_exec 'SSH' 'AUTH_SERVER' "${_autodc_status}")
          if [[ "${_test}" == "${_autodc_success}" ]]; then
            log "${AUTH_SERVER}${_autodc_release} is ready."
            sleep ${_sleep}
            break
          elif (( ${_loop} > ${_attempts} )); then
            log "Error ${_error}: ${AUTH_SERVER}${_autodc_release} VM running: giving up after ${_loop} tries."
            _result=$(source /etc/profile.d/nutanix_env.sh \
              && for _vm in $(source /etc/profile.d/nutanix_env.sh && acli vm.list | grep ${AUTH_SERVER}${_autodc_release}) ; do acli -y vm.delete $_vm; done)
            # acli image.delete ${AUTH_SERVER}${_autodc_release}
            log "Remediate by deleting the ${AUTH_SERVER}${_autodc_release} VM from PE (just attempted by this script: ${_result}) and then running acli $_"
            exit ${_error}
          else
            log "_test ${_loop}/${_attempts}=|${_test}|: sleep ${_sleep} seconds..."
            sleep ${_sleep}
          fi
        done

        log "Create Reverse Lookup Zone on ${AUTH_SERVER}${_autodc_release} VM..."
        _attempts=3
            _loop=0

        while true ; do
          (( _loop++ ))
          remote_exec 'SSH' 'AUTH_SERVER' \
            "samba-tool dns zonecreate dc${_autodc_index} ${OCTET[2]}.${OCTET[1]}.${OCTET[0]}.in-addr.arpa ${_autodc_auth} && ${_autodc_restart}" \
            'OPTIONAL'
          sleep ${_sleep}

          dns_check "dc${_autodc_index}.${AUTH_FQDN}"
          _result=$?

          if (( ${_result} == 0 )); then
            log "Success: DNS record dc${_autodc_index}.${AUTH_FQDN} set."
            break
          elif (( ${_loop} > ${_attempts} )); then
            if (( ${_autodc_release} < 2 )); then
              log "Error ${_error}: ${AUTH_SERVER}${_autodc_release}: giving up after ${_loop} tries; deleting VM..."
              acli "-y vm.delete ${AUTH_SERVER}${_autodc_release}"
              exit ${_error}
            fi
          else
            log "dns_check ${_loop}/${_attempts}=|${_result}|: sleep ${_sleep} seconds..."
            sleep ${_sleep}
          fi
        done

        # Adding the needed group and users to the AutoDC that may be used. Calm would otherwise have no BootInfra Project
        remote_exec 'SSH' 'AUTH_SERVER' \
          'samba-tool group add "SSP Custom"' \
          'OPTIONAL'
        sleep ${_sleep}
        remote_exec 'SSH' 'AUTH_SERVER' \
          'for i in `samba-tool user list | grep ^user`; do samba-tool group addmembers "SSP Custom" $i;done' \
          'OPTIONAL'
         sleep ${_sleep}

      fi
      ;;
  esac
}

###############################################################################################################################################################################
# Routine to get the Nutanix Files injected
###############################################################################################################################################################################

function files_install() {
  local  _ncli_softwaretype='FILE_SERVER'
  local _ncli_software_type='afs'
  local               _test

  dependencies 'install' 'jq' || exit 13

  log "IDEMPOTENCY: checking for ${_ncli_software_type} completed..."
  _test=$(source /etc/profile.d/nutanix_env.sh \
    && ncli --json=true software list \
    | jq -r \
      '.data[] | select(.softwareType == "'${_ncli_softwaretype}'") | select(.status == "COMPLETED") | .version')

  if [[ ${_test} != "${FILES_VERSION}" ]]; then
    log "Files ${FILES_VERSION} not completed. ${_test}"
    ntnx_download "${_ncli_software_type}"
  else
    log "IDEMPOTENCY: Files ${FILES_VERSION} already completed."
  fi
}

###############################################################################################################################################################################
# Routine to get the Nutanix File Analytics injected
###############################################################################################################################################################################

function file_analytics_install() {
  local  _ncli_softwaretype='FILE_ANALYTICS'
  local _ncli_software_type='file_analytics'
  local               _test

  dependencies 'install' 'jq' || exit 13

  log "IDEMPOTENCY: checking for ${_ncli_software_type} completed..."
  _test=$(source /etc/profile.d/nutanix_env.sh \
    && ncli --json=true software list \
    | jq -r \
      '.data[] | select(.softwareType == "'${_ncli_softwaretype}'") | select(.status == "COMPLETED") | .version')

  if [[ ${_test} != "${FILE_ANALYTICS_VERSION}" ]]; then
    log "Files ${FILE_ANALYTICS_VERSION} not completed. ${_test}"
    ntnx_download "${_ncli_software_type}"
  else
    log "IDEMPOTENCY: Files ${FILE_ANALYTICS_VERSION} already completed."
  fi
}

###############################################################################################################################################################################
# Create File Server
###############################################################################################################################################################################

function create_file_server() {
  #local CURL_HTTP_OPTS=' --max-time 25 --silent --show-error --header Content-Type:application/json --header Accept:application/json --insecure '
  local      _fileserver_name="BootcampFS"
  local     _internal_nw_name="${1}"
  local     _internal_nw_uuid
  local     _external_nw_name="${2}"
  local     _external_nw_uuid
  local                 _test
  local     _maxtries=30
  local     _tries=0
  local _httpURL="https://localhost:9440/PrismGateway/services/rest/v1/vfilers"
  local _grab_afs_version="https://localhost:9440/PrismGateway/services/rest/v1/upgrade/afs/softwares"
  local _ntp_formatted="$(echo $NTP_SERVERS | sed -r 's/[^,]+/'\"'&'\"'/g')"

  # Get dynamically the version of the AFS that has been installed
  afs_version=$(curl ${CURL_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X GET ${_grab_afs_version} | jq '.entities[] | select (.status=="COMPLETED") .version' | tr -d \")

  log "Found installed version: $afs_version of Nutanix Files..."

  echo "Get cluster network and storage container UUIDs..."
  _internal_nw_uuid=$(acli net.get ${_internal_nw_name} \
    | grep "uuid" | cut -f 2 -d ':' | xargs)
  _external_nw_uuid=$(acli net.get ${_external_nw_name} \
    | grep "uuid" | cut -f 2 -d ':' | xargs)
  _storage_default_uuid=$(ncli container ls name=${STORAGE_DEFAULT} \
    | grep Uuid | grep -v Pool | cut -f 2 -d ':' | xargs)
  echo "${_internal_nw_name} network UUID: ${_internal_nw_uuid}"
  echo "${_external_nw_name} network UUID: ${_external_nw_uuid}"
  echo "${STORAGE_DEFAULT} storage container UUID: ${_storage_default_uuid}"

  HTTP_JSON_BODY=$(cat <<EOF
  {
   "name":"${_fileserver_name}",
   "numCalculatedNvms":"1",
   "numVcpus":"4",
   "memoryGiB":"12",
   "internalNetwork":{
      "subnetMask":"",
      "defaultGateway":"",
      "uuid":"${_internal_nw_uuid}",
      "pool":[

      ]
   },
   "externalNetworks":[
      {
         "subnetMask":"",
         "defaultGateway":"",
         "uuid":"${_external_nw_uuid}",
         "pool":[

         ]
      }
   ],
   "windowsAdDomainName":"${AUTH_FQDN}",
   "windowsAdUsername":"${AUTH_ADMIN_USER}",
   "windowsAdPassword":"${AUTH_ADMIN_PASS}",
   "dnsServerIpAddresses":[
      "${AUTH_HOST}"
   ],
   "ntpServers":[
      ${_ntp_formatted}
   ],
   "sizeGib":"1024",
   "version":"${afs_version}",
   "dnsDomainName":"${AUTH_FQDN}",
   "nameServicesDTO":{
      "adDetails":{
         "windowsAdDomainName":"${AUTH_FQDN}",
         "windowsAdUsername":"${AUTH_ADMIN_USER}",
         "windowsAdPassword":"${AUTH_ADMIN_PASS}",
         "addUserAsFsAdmin":true,
         "organizationalUnit":"",
         "preferredDomainController":"",
         "overwriteUserAccount":false,
         "rfc2307Enabled":false,
         "useSameCredentialsForDns":false,
         "protocolType":"1"
      }
   },
   "addUserAsFsAdmin":true,
   "organizationalUnit":"",
   "preferredDomainController":"",
   "fsDnsOperationsDTO":{
      "dnsOpType":"MS_DNS",
      "dnsServer":"",
      "dnsUserName":"${AUTH_ADMIN_USER}",
      "dnsPassword":"${AUTH_ADMIN_PASS}"
   },
   "pdName":"NTNX-${_fileserver_name}"
}
EOF
)

  # Start the create process
  #_response=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST -d ${HTTP_JSON_BODY} ${_httpURL}| grep "taskUuid" | wc -l)
echo $HTTP_JSON_BODY

# execute the API call to create the file server
  _response=$(curl ${CURL_POST_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST --data "${HTTP_JSON_BODY}" ${_httpURL} | grep "taskUuid" | wc -l)

#curl $CURL_HTTP_OPTS --user $PRISM_ADMIN:$PE_PASSWORD -X POST -d $HTTP_JSON_BODY $_httpURL

  # Check to ensure we get a response back, then start checking for the file server creation
  if [[ ! -z $_response ]]; then
#    # Check if Files has been enabled
    _checkresponse=$(curl ${CURL_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X GET ${_httpURL}| grep $_fileserver_name | wc -l)
    while [[ $_checkresponse -ne 1 && $_tries -lt $_maxtries ]]; do
      log "File Server Not yet created. $_tries/$_maxtries... sleeping 1 minute"
      sleep 1m
      _checkresponse=$(curl ${CURL_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X GET ${_httpURL}| grep $_fileserver_name | wc -l)
      ((_tries++))
    done
    if [[ $_checkresponse -eq 1 ]]; then
      echo "File Server has been created."
    else
      echo "File Server creation failed. Check the staging logs."
    fi
  else
    echo "File Server is not being created, check the staging logs."
  fi
}

###############################################################################################################################################################################
# Create File Analytics Server
###############################################################################################################################################################################

function create_file_analytics_server() {
  #local CURL_HTTP_OPTS=' --max-time 25 --silent --show-error --header Content-Type:application/json --header Accept:application/json --insecure '
  local _file_analytics_server_name="BootcampFileAnalytics"
  local _nw_name="${NW1_NAME}"
  local _nw_uuid
  local _test
  local _maxtries=30
  local _tries=0
  local _ntp_formatted="$(echo $NTP_SERVERS | sed -r 's/[^,]+/'\"'&'\"'/g')"
  local CURL_HTTP_OPTS=" --max-time 25 --silent --header Content-Type:application/json --header Accept:application/json  --insecure "

  log "Installing File Analytics version: ${FILE_ANALYTICS_VERSION}"

  echo "Get cluster network and storage container UUIDs..."

  # Get the Network UUIDs
  #_nw_uuid=$(acli net.get ${_nw_name} | grep "uuid" | cut -f 2 -d ':' | xargs)
  log "Get cluster network UUID"

  #_nw_uuid=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST --data '{"kind":"subnet","filter": "name==Primary"}' 'https://localhost:9440/api/nutanix/v3/subnets/list' | jq -r '.entities[] | .metadata.uuid' | tr -d \")

  #_nw_uuid=$(curl ${CURL_HTTP_OPTS} -X POST 'https://localhost:9440/api/nutanix/v3/subnets/list' --user ${PRISM_ADMIN}:${PE_PASSWORD} --data '{"kind":"subnet","filter": "name==Secondary"}' | jq -r '.entities[] | .metadata.uuid' | tr -d \")

  #_nw_uuid=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST --data '{"kind":"subnet","filter": "name==Secondary"}' 'https://localhost:9440/api/nutanix/v3/subnets/list' | jq -r '.entities[] | .metadata.uuid' | tr -d \")
  _nw_uuid=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST --data '{"kind":"subnet","filter": "name==Primary"}' 'https://localhost:9440/api/nutanix/v3/subnets/list' | jq -r '.entities[] | .metadata.uuid' | tr -d \")

  # Get the Container UUIDs
  log "Get ${STORAGE_DEFAULT} Container UUID"
  _storage_default_uuid=$(ncli container ls name=${STORAGE_DEFAULT} | grep Uuid | grep -v Pool | cut -f 2 -d ':' | xargs)

  echo "Secondary network UUID: ${_nw_uuid}"
  echo "${STORAGE_DEFAULT} storage container UUID: ${_storage_default_uuid}"


HTTP_JSON_BODY=$(cat <<EOF
{
                "image_version": "${FILE_ANALYTICS_VERSION}",
                "vm_name": "${_file_analytics_server_name}",
                "container_uuid": "${_storage_default_uuid}",
                "container_name": "${STORAGE_DEFAULT}",
                "network": {
                                "uuid": "${_nw_uuid}",
                                "ip": "",
                                "netmask": "",
                                "gateway": ""
                },
                "resource": {
                                "memory": "24",
                                "cores": "2",
                                "vcpu": "4"
                },
                "dns_servers": ["${AUTH_HOST}"],
                "ntp_servers": [${_ntp_formatted}],
                "disk_size": "3"
}
EOF
)

  # Start the create process
  #_response=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST -d ${HTTP_JSON_BODY} ${_httpURL}| grep "taskUuid" | wc -l)

  # execute the API call to create the file analytics server
  #_response=$(curl ${CURL_POST_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST --data "${HTTP_JSON_BODY}" 'https://localhost:9440/PrismGateway/services/rest/v2.0/analyticsplatform' | grep "taskUuid" | wc -l)
  echo "Creating File Anlytics Server Now"
  echo $HTTP_JSON_BODY

  #curl ${CURL_HTTP_OPTS} --request POST 'https://localhost:9440/PrismGateway/services/rest/v2.0/analyticsplatform' --user ${PRISM_ADMIN}:${PE_PASSWORD} --data "${HTTP_JSON_BODY}"

  #sleep 300

  _task_id=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST --data "${HTTP_JSON_BODY}" 'https://localhost:9440/PrismGateway/services/rest/v2.0/analyticsplatform' | jq -r '.task_uuid' | tr -d \")

  log "Task uuid for the FileAnalytics server is " $_task_id " ....."

  # If there has been a reply (task_id) then the URL has accepted by PC
  # Changed (()) to [] so it works....

  if [ -z "$_task_id" ]; then
       log "File Analytics Deploy has encountered an eror..."
  else
       log "File Analytics Deploy started.."
       set _loops=0 # Reset the loop counter so we restart the amount of loops we need to run
      # Run the progess checker
       loop
  fi

}

###############################################################################################################################################################################
# Routine to create the networks
###############################################################################################################################################################################


function network_configure() {
  local _network_name="${NW1_NAME}"

  if [[ ! -z "${NW2_NAME}" ]]; then
    #TODO: accommodate for X networks!
    _network_name="${NW2_NAME}"
  fi

  if [[ ! -z $(acli "net.list" | grep ${_network_name}) ]]; then
    log "IDEMPOTENCY: ${_network_name} network set, skip."
  else
    args_required 'AUTH_DOMAIN IPV4_PREFIX AUTH_HOST'

    if [[ ! -z $(acli "net.list" | grep 'Rx-Automation-Network') ]]; then
      log "Remove Rx-Automation-Network..."
      acli "-y net.delete Rx-Automation-Network"
    fi

    log "Create primary network: Name: ${NW1_NAME}, VLAN: ${NW1_VLAN}, Subnet: ${NW1_SUBNET}, Domain: ${AUTH_DOMAIN}, Pool: ${NW1_DHCP_START} to ${NW1_DHCP_END}"
    acli "net.create ${NW1_NAME} vlan=${NW1_VLAN} ip_config=${NW1_SUBNET}"
    acli "net.update_dhcp_dns ${NW1_NAME} servers=${AUTH_HOST},${DNS_SERVERS} domains=${AUTH_FQDN}"
    acli "  net.add_dhcp_pool ${NW1_NAME} start=${NW1_DHCP_START} end=${NW1_DHCP_END}"

    if [[ ! -z "${NW2_NAME}" ]]; then
      log "Create secondary network: Name: ${NW2_NAME}, VLAN: ${NW2_VLAN}, Subnet: ${NW2_SUBNET}, Pool: ${NW2_DHCP_START} to ${NW2_DHCP_END}"
      acli "net.create ${NW2_NAME} vlan=${NW2_VLAN} ip_config=${NW2_SUBNET}"
      acli "net.update_dhcp_dns ${NW2_NAME} servers=${AUTH_HOST},${DNS_SERVERS} domains=${AUTH_FQDN}"
      acli "  net.add_dhcp_pool ${NW2_NAME} start=${NW2_DHCP_START} end=${NW2_DHCP_END}"
    fi
  fi
}

###############################################################################################################################################################################
# Routine to create the networks for POC Workshop
###############################################################################################################################################################################


function pocguide_network_configure() {
  local _network_name="${NW1_NAME}"

  if [[ ! -z "${NW2_NAME}" ]]; then
    #TODO: accommodate for X networks!
    _network_name="${NW2_NAME}"
  fi

  if [[ ! -z $(acli "net.list" | grep ${_network_name}) ]]; then
    log "IDEMPOTENCY: ${_network_name} network set, skip."
  else
    args_required 'AUTH_DOMAIN IPV4_PREFIX AUTH_HOST'

    if [[ ! -z $(acli "net.list" | grep 'Rx-Automation-Network') ]]; then
      log "Remove Rx-Automation-Network..."
      acli "-y net.delete Rx-Automation-Network"
    fi

    log "Create primary network: Name: ${NW1_NAME}, VLAN: ${NW1_VLAN}, Subnet: ${NW1_SUBNET}, Domain: ${AUTH_DOMAIN}, Pool: ${NW1_DHCP_START} to ${NW1_DHCP_END}"
    acli "net.create ${NW1_NAME} vlan=${NW1_VLAN} ip_config=${NW1_SUBNET}"
    acli "net.update_dhcp_dns ${NW1_NAME} servers=${AUTH_HOST},${DNS_SERVERS} domains=${AUTH_FQDN}"
    acli "  net.add_dhcp_pool ${NW1_NAME} start=${NW1_DHCP_START} end=${NW1_DHCP_END}"

    if [[ ! -z "${NW2_NAME}" ]]; then
      log "Create secondary network: Name: ${NW2_NAME}, VLAN: ${NW2_VLAN}, Subnet: ${NW2_SUBNET}, Pool: ${NW2_DHCP_START} to ${NW2_DHCP_END}"
      acli "net.create ${NW2_NAME} vlan=${NW2_VLAN} ip_config=${NW2_SUBNET}"
      #acli "net.update_dhcp_dns ${NW2_NAME} servers=${AUTH_HOST},${DNS_SERVERS} domains=${AUTH_FQDN}"
      #acli "  net.add_dhcp_pool ${NW2_NAME} start=${NW2_DHCP_START} end=${NW2_DHCP_END}"
    fi
  fi
}

###############################################################################################################################################################################
# Create the Secondary network based on the 3rd OCTET of the cluster for SNCs
###############################################################################################################################################################################

function secondary_network_SNC(){
    # Set some needed parameters
    local SEC_NETW=${OCTET[3]}
    local SEC_NETW_VLAN=${OCTET[3]}
    local CURL_HTTP_OPTS=" --max-time 25 --silent --header Content-Type:application/json --header Accept:application/json  --insecure "

    # Get the last OCTET from the IP address of the AutoAD server
    #payload='{"filter": "vm_name==AutoAD","kind": "vm"}'
    #url="https://localhost:9440/api/nutanix/v3/vms/list"
    #autoad_ip=$(curl -X POST ${url} -d "${payload}" ${CURL_POST_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} | jq '.entities[].status.resources.nic_list[].ip_endpoint_list[0].ip' | tr -d \"| cut -d '.' -f 4)

    # Get UUID of the AutoAD
    #autoad_uuid=$(curl -X POST ${url} -d "${payload}" ${CURL_POST_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} | jq '.entities[].metadata.uuid' | tr -d \")

    # Set the right information for the network
    json_payload='{"name":"Secondary","vlanId":"'${SEC_NETW_VLAN}'","ipConfig":{"dhcpOptions":{"domainNameServers":"'${AUTH_HOST}'","domainSearch":"ntxlab.local","domainName":"ntnxlab.local"},"networkAddress":"10.10.'${SEC_NETW_VLAN}'.0","prefixLength":"24","defaultGateway":"10.10.'${SEC_NETW_VLAN}'.1","pool":[
                {
                    "range":"10.10.'${SEC_NETW_VLAN}'.90 10.10.'${SEC_NETW_VLAN}'.200"
                }
                ]
            }
        }
    }'
    echo ${json_payload}

    # Create the network
    url="https://localhost:9440/api/nutanix/v0.8/networks"
    network_uuid=$(curl -X POST ${url} -d "${json_payload}" ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD})
    echo ${network_uuid}
    if [[ -z ${network_uuid} ]]; then
      log "The secondary network has not been created..."
    else
      log "The secondary network has been created..."
    fi

    # Add second nic into the AutoAD VM
    #url="https://localhost:9440/PrismGateway/services/rest/v2.0/vms/${autoad_uuid}/nics"
    #json_payload='{"spec_list":[{"network_uuid":"'${network_uuid}'","requested_ip_address":"10.10.'${SEC_NETW_VLAN}'.'${autoad_ip}'","is_connected":true,"vlan_id":"'${SEC_NETW_VLAN}'"}]}'

    #task_uuid=$(curl -X POST ${url} -d "${json_payload}" ${CURL_POST_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} | jq '.task_uuid' | tr -d \")
    #if [[ -z ${task_uuid} ]]; then
    #    log "The AutoAD didn't receive the second network card..."
    #else
    #    log "The AutoAD has it's second network card assigned..."
    #fi

}

###############################################################################################################################################################################
# Routine to create the networks for Era bootcamp
###############################################################################################################################################################################


function era_network_configure() {
  local _network_name="${NW1_NAME}"


  if [[ ! -z $(acli "net.list" | grep ${_network_name}) ]]; then
    log "IDEMPOTENCY: ${_network_name} network set, skip."
  else
    args_required 'AUTH_DOMAIN IPV4_PREFIX AUTH_HOST'

    if [[ ! -z $(acli "net.list" | grep 'Rx-Automation-Network') ]]; then
      log "Remove Rx-Automation-Network..."
      acli "-y net.delete Rx-Automation-Network"
    fi

    log "Create primary network: Name: ${NW1_NAME}, VLAN: ${NW1_VLAN}, Subnet: ${NW1_SUBNET}, Domain: ${AUTH_DOMAIN}, Pool: ${NW1_DHCP_START} to ${NW1_DHCP_END}"
    acli "net.create ${NW1_NAME} vlan=${NW1_VLAN} ip_config=${NW1_SUBNET}"
    acli "net.update_dhcp_dns ${NW1_NAME} servers=${AUTH_HOST},${DNS_SERVERS} domains=${AUTH_FQDN}"
    acli "  net.add_dhcp_pool ${NW1_NAME} start=${NW1_DHCP_START} end=${NW1_DHCP_END}"

    # so we do not need DHCP
    if [[ ! -z "${NW2_NAME}" ]]; then
      log "Create secondary network: Name: ${NW2_NAME}, VLAN: ${NW2_VLAN}, Subnet: ${NW2_SUBNET}"
      acli "net.create ${NW2_NAME} vlan=${NW2_VLAN} ip_config=${NW2_SUBNET}"
      acli "net.update_dhcp_dns ${NW2_NAME} servers=${AUTH_HOST},${DNS_SERVERS} domains=${AUTH_FQDN}"
      acli "  net.add_dhcp_pool ${NW2_NAME} start=${NW2_DHCP_START} end=${NW2_DHCP_END}"
    fi

    if [[ ! -z "${NW3_NAME}" ]]; then
      log "Create EraManaged network: Name: ${NW3_NAME}, VLAN: ${NW3_VLAN}"
      acli "net.create ${NW3_NAME} vlan=${NW2_VLAN}"
    fi

  fi
}

###############################################################################################################################################################################
# Routine to check if the registration of PE was successful
###############################################################################################################################################################################

function cluster_check() {
  local     _attempts=20
  local         _loop=0
  local   _pc_version
  local        _sleep=60
  local         _test=1
  local    _test_exit
  local CURL_HTTP_OPTS=' --max-time 25 --silent --header Content-Type:application/json --header Accept:application/json  --insecure '

  log "PC is installed, registering the PE to PC"
   # Enable the PE to PC registration
   _json_data="{\"ipAddresses\":[\"${PC_HOST}\"],\"username\":\"${PRISM_ADMIN}\",\"password\":\"${PE_PASSWORD}\",\"port\":null}"
   _response=$(curl -X POST $CURL_HTTP_OPTS --user ${PRISM_ADMIN}:${PE_PASSWORD} https://localhost:9440/PrismGateway/services/rest/v1/multicluster/add_to_multicluster -d $_json_data | jq '.value')

   # Let's sleep a few seconds before moving on
   sleep 5

   # Checking if the registration has worked
   _pc_ip_addr=$(curl $CURL_HTTP_OPTS --user ${PRISM_ADMIN}:${PE_PASSWORD} https://localhost:9440/PrismGateway/services/rest/v1/multicluster/cluster_external_state | jq '.[].clusterDetails.ipAddresses[0]' | tr -d \")
   while [[ -z $_pc_ip_addr ]]
   do
      log "Registering PE has failed, retrying"
      curl -X POST $CURL_HTTP_OPTS --user ${PRISM_ADMIN}:${PE_PASSWORD} https://localhost:9440/PrismGateway/services/rest/v1/multicluster/add_to_multicluster -d $_json_data
      (( _loop++ ))
      _pc_ip_addr=$(curl $CURL_HTTP_OPTS --user ${PRISM_ADMIN}:${PE_PASSWORD} https://localhost:9440/PrismGateway/services/rest/v1/multicluster/cluster_external_state | jq '.[].clusterDetails.ipAddresses[0]' | tr -d \")
      sleep 5
      log "Sleeping for 5 seconds before retrying...$_loop/$_attempts"
      if [[ $_loop -gt $_attempts ]]; then
        log "We have tried 10 times and the cluster is not able to register... Exiting the script!!"
        exit 1
      fi
   done
   log "PE has been registered to PC... Proceeding..."
}

###############################################################################################################################################################################
# Routine to configure the PC and handoff to the PC local installation
###############################################################################################################################################################################

function pc_configure() {
  args_required 'PC_LAUNCH RELEASE'
  local      _command
  local    _container
  local _dependencies="global.vars.sh lib.pc.sh ${PC_LAUNCH}"

  # If we are being called via the we-*.sh, we need to change the lib.common.sh to we-lib.common.sh
  if [[ ${PC_LAUNCH} != *"we-"* ]]; then
    _dependencies+=" lib.common.sh"
  else
    _dependencies+=" we-lib.common.sh"
  fi

  if [[ -e ${RELEASE} ]]; then
    _dependencies+=" ${RELEASE}"
  else
    log 'Warning: did NOT find '${RELEASE}
  fi
  log "Send configuration scripts to PC and remove: ${_dependencies}"
  remote_exec 'scp' 'PC' "${_dependencies}" && rm -f ${_dependencies} lib.pe.sh

  _dependencies="bin/${JQ_REPOS[0]##*/} ${SSHPASS_REPOS[0]##*/} id_rsa.pub"

  log "OPTIONAL: Send binary dependencies to PC: ${_dependencies}"
  remote_exec 'scp' 'PC' "${_dependencies}" 'OPTIONAL'

  for _container in epsilon nucalm ; do
    if [[ -e ${_container}.tar ]]; then
      log "Uploading Calm container updates in background..."
      remote_exec 'SCP' 'PC' ${_container}.tar 'OPTIONAL' &
    fi
  done
  #####################################################################################
  ### Handing of to the PC for rest of the installation
  #####################################################################################

  ## TODO: If DEBUG is set, we run the below command with bash -x
  _command="EMAIL=${EMAIL} \
    PC_HOST=${PC_HOST} PE_HOST=${PE_HOST} PE_PASSWORD=${PE_PASSWORD} \
    PC_LAUNCH=${PC_LAUNCH} PC_VERSION=${PC_VERSION} nohup bash ${HOME}/${PC_LAUNCH} PC"
  log "Remote asynchroneous launch PC configuration script... ${_command}"
  remote_exec 'ssh' 'PC' "${_command} >> ${HOME}/${PC_LAUNCH%%.sh}.log 2>&1 &"
  log "PC Configuration complete: try Validate Staged Clusters now."
}

###############################################################################################################################################################################
# Routine to install the PC in the PE
###############################################################################################################################################################################
function pc_install() {
  local    _ncli_softwaretype='PRISM_CENTRAL_DEPLOY'
  local              _nw_name="${1}"
  local              _nw_uuid
  local           _pc_version
  local _should_auto_register
  local _storage_default_uuid
  local                 _test

  log "IDEMPOTENCY: Checking PC API responds, curl failures are acceptable..."
  prism_check 'PC' 2 0

  if (( $? == 0 )) ; then
    log "IDEMPOTENCY: PC API responds, skip."
  else
    log "Get cluster network and storage container UUIDs..."
    _nw_uuid=$(acli "net.get ${_nw_name}" \
      | grep "uuid" | cut -f 2 -d ':' | xargs)
    _storage_default_uuid=$(ncli container ls name=${STORAGE_IMAGES} \
      | grep Uuid | grep -v Pool | cut -f 2 -d ':' | xargs)
    #_storage_default_uuid=$(ncli container ls name=${STORAGE_DEFAULT} \
    #  | grep Uuid | grep -v Pool | cut -f 2 -d ':' | xargs)
    log "${_nw_name} network UUID: ${_nw_uuid}"
    log "${STORAGE_DEFAULT} storage container UUID: ${_storage_default_uuid}"

    _test=$(source /etc/profile.d/nutanix_env.sh \
      && ncli --json=true software list \
      | jq -r \
        '.data[] | select(.softwareType == "'${_ncli_softwaretype}'") | select(.status == "COMPLETED") | .version')

    if [[ ${_test} != "${PC_VERSION}" ]]; then
      log "PC-${PC_VERSION} not completed. ${_test}"
      ntnx_download "${_ncli_softwaretype}"
    else
      log "IDEMPOTENCY: PC-${PC_VERSION} upload already completed."
    fi

    # shellcheck disable=2206
    _pc_version=(${PC_VERSION//./ })
    if (( ${_pc_version[0]} == 5 && ${_pc_version[1]} <= 6 )); then
      _should_auto_register='"should_auto_register":true,'
    fi

    log "Deploy Prism Central (typically takes 17+ minutes)..."
    # TODO:160 make scale-out & dynamic, was: 4vCPU/16GB = 17179869184, 8vCPU/40GB = 42949672960
    # Sizing suggestions, certified configurations:
    # https://portal.nutanix.com/#/page/docs/details?targetId=Release-Notes-Prism-Central-v591:sha-pc-scalability-r.html

    # TODO:10 network_configuration.{subnet_mask|default_gateway}
    HTTP_BODY=$(cat <<EOF
{
  "resources": {
    ${_should_auto_register}
    "version":"${PC_VERSION}",
    "pc_vm_list":[{
      "data_disk_size_bytes":536870912000,
      "nic_list":[{
        "network_configuration":{
          "subnet_mask":"${SUBNET_MASK}",
          "network_uuid":"${_nw_uuid}",
          "default_gateway":"${NW1_GATEWAY}"
        },
        "ip_list":["${PC_HOST}"]
      }],
      "dns_server_ip_list":["${AUTH_HOST}"],
      "container_uuid":"${_storage_default_uuid}",
      "num_sockets":8,
      "memory_size_bytes":42949672960,
      "vm_name":"Prism Central ${PC_VERSION}"
    }]
  }
}
EOF
    )
    local _test
    _test=$(curl ${CURL_POST_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} \
      -X POST --data "${HTTP_BODY}" \
      https://localhost:9440/api/nutanix/v3/prism_central)
    #log "_test=|${_test}|"
  fi
}

###############################################################################################################################################################################
# Routine to set the PE to use the AutoDC for authentication
###############################################################################################################################################################################
function pe_auth() {
  local           _aos
  local   _aos_version
  local _directory_url="ldaps://${AUTH_HOST}/"
  local         _error=45

  args_required 'AUTH_DOMAIN AUTH_FQDN AUTH_HOST AUTH_ADMIN_USER AUTH_ADMIN_PASS AUTH_ADMIN_GROUP'

  if [[ -z $(ncli authconfig list-directory name=${AUTH_DOMAIN} | grep Error) ]]; then
    log "IDEMPOTENCY: ${AUTH_DOMAIN} directory set, skip."
  else
    # https://portal.nutanix.com/kb/1005
    _aos=$(ncli --json=true cluster info | jq -r .data.version)

    if [[ ! -z ${_aos} ]]; then
      # shellcheck disable=2206
      _aos_version=(${_aos//./ })
      if (( ${_aos_version[0]} >= 5 && ${_aos_version[1]} >= 9 )); then
        _directory_url="ldap://${AUTH_HOST}:${LDAP_PORT}"
        log "Adjusted directory-url=${_directory_url} because AOS-${_aos} >= 5.9"
      fi
    else
      log "Error ${_error}: couldn't determine AOS version=${_aos}"
      exit ${_error}
    fi

    log "Configure PE external authentication"
    ncli authconfig add-directory \
      directory-type=ACTIVE_DIRECTORY \
      connection-type=LDAP directory-url="${_directory_url}" \
      domain="${AUTH_FQDN}" \
      name="${AUTH_DOMAIN}" \
      service-account-username="${AUTH_ADMIN_USER}" \
      service-account-password="${AUTH_ADMIN_PASS}"

    log "Configure PE role map"
    ncli authconfig add-role-mapping \
      role=ROLE_CLUSTER_ADMIN \
      entity-type=group name="${AUTH_DOMAIN}" \
      entity-values="${AUTH_ADMIN_GROUP}"
  fi
}

###############################################################################################################################################################################
# Routine set PE's initial configuration
###############################################################################################################################################################################
function pe_init() {
  args_required 'DATA_SERVICE_IP EMAIL \
    SMTP_SERVER_ADDRESS SMTP_SERVER_FROM SMTP_SERVER_PORT \
    STORAGE_DEFAULT STORAGE_POOL STORAGE_IMAGES \
    SLEEP ATTEMPTS'

  #if [[ `ncli cluster get-params | grep 'External Data' | \
  #       awk -F: '{print $2}' | tr -d '[:space:]'` == "${DATA_SERVICE_IP}" ]]; then
  #  log "IDEMPOTENCY: Data Services IP set, skip."
  #else
    log "Configure SMTP"
    ncli cluster set-smtp-server port=${SMTP_SERVER_PORT} \
      from-email-address=${SMTP_SERVER_FROM} address=${SMTP_SERVER_ADDRESS}
    ${HOME}/serviceability/bin/email-alerts --to_addresses="${EMAIL}" \
      --subject="[pe_init:Config SMTP:alert test] $(ncli cluster get-params)" \
      && ${HOME}/serviceability/bin/send-email

    log "Configure NTP"
    ncli cluster add-to-ntp-servers servers=${NTP_SERVERS}

    log "Rename default container to ${STORAGE_DEFAULT}"
    default_container=$(ncli container ls | grep -P '^(?!.*VStore Name).*Name' \
      | cut -d ':' -f 2 | sed s/' '//g | grep '^default-container-')
    ncli container edit name="${default_container}" new-name="${STORAGE_DEFAULT}"

    log "Rename default storage pool to ${STORAGE_POOL}"
    default_sp=$(ncli storagepool ls | grep 'Name' | cut -d ':' -f 2 | sed s/' '//g)
    ncli sp edit name="${default_sp}" new-name="${STORAGE_POOL}"

    log "Check if there is a container named ${STORAGE_IMAGES}, if not create one"
    (ncli container ls | grep -P '^(?!.*VStore Name).*Name' \
      | cut -d ':' -f 2 | sed s/' '//g | grep "^${STORAGE_IMAGES}" > /dev/null 2>&1) \
      && log "Container ${STORAGE_IMAGES} exists" \
      || ncli container create name="${STORAGE_IMAGES}" sp-name="${STORAGE_POOL}"

    # Set external IP address:
    #ncli cluster edit-params external-ip-address=${PE_HOST}

    log "Set Data Services IP address to ${DATA_SERVICE_IP}"
    ncli cluster edit-params external-data-services-ip-address=${DATA_SERVICE_IP}
  #fi
}

###############################################################################################################################################################################
# Routine to accept the EULA and disable pulse
###############################################################################################################################################################################
function pe_license() {
  local _test
  args_required 'CURL_POST_OPTS PE_PASSWORD'

  log "IDEMPOTENCY: Checking PC API responds, curl failures are acceptable..."
  prism_check 'PC' 2 0

  if (( $? == 0 )) ; then
    log "IDEMPOTENCY: PC API responds, skip"
  else
    _test=$(curl ${CURL_POST_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST --data '{
      "username": "SE with $(basename ${0})",
      "companyName": "Nutanix",
      "jobTitle": "SE"
    }' https://localhost:9440/PrismGateway/services/rest/v1/eulas/accept)
    log "Validate EULA on PE: _test=|${_test}|"

    _test=$(curl ${CURL_POST_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X PUT --data '{
      "defaultNutanixEmail": null,
      "emailContactList": null,
      "enable": false,
      "enableDefaultNutanixEmail": false,
      "isPulsePromptNeeded": false,
      "nosVersion": null,
      "remindLater": null,
      "verbosityType": null
    }' https://localhost:9440/PrismGateway/services/rest/v1/pulse)
    log "Disable Pulse in PE: _test=|${_test}|"

    #echo; log "Create PE Banner Login" # TODO: for PC, login banner
    # https://portal.nutanix.com/#/page/docs/details?targetId=Prism-Central-Guide-Prism-v56:mul-welcome-banner-configure-pc-t.html
    # curl ${CURL_POST_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST --data \
    #  '{type: "welcome_banner", key: "welcome_banner_status", value: true}' \
    #  https://localhost:9440/PrismGateway/services/rest/v1/application/system_data
    #curl ${CURL_POST_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST --data
    #  '{type: "welcome_banner", key: "welcome_banner_content", value: "HPoC '${OCTET[2]}' password = '${PE_PASSWORD}'"}' \
    #  https://localhost:9440/PrismGateway/services/rest/v1/application/system_data
  fi
}

###############################################################################################################################################################################
# Routine to unregister PE from PC
###############################################################################################################################################################################
function pc_unregister {
  local _cluster_uuid
  local      _pc_uuid
  # https://portal.nutanix.com/kb/4944

  # PE:
  cluster status # check
  ncli -h true multicluster remove-from-multicluster \
    external-ip-address-or-svm-ips=${PC_HOST} \
    username=${PRISM_ADMIN} password=${PE_PASSWORD} force=true
    # Error: This cluster was never added to Prism Central
  ncli multicluster get-cluster-state # check for none
  _cluster_uuid=$(ncli cluster info | grep -i uuid | awk -F: '{print $2}' | tr -d '[:space:]')

  exit 0
  # PC: remote_exec 'PC'
  chmod u+x /home/nutanix/bin/unregistration_cleanup.py \
  && python /home/nutanix/bin/unregistration_cleanup.py ${_cluster_uuid}
  # Uuid of current cluster cannot be passed to cleanup
  _pc_uuid=$(cluster info) # no such command!
  # PE:
  chmod u+x /home/nutanix/bin/unregistration_cleanup.py \
  && python /home/nutanix/bin/unregistration_cleanup.py ${_pc_uuid}

  # Troubleshooting
  cat ~/data/logs/unregistration_cleanup.log

  pc_destroy
}

###############################################################################################################################################################################
# Routine to destroy the PC VM
###############################################################################################################################################################################
function pc_destroy() {
  local _vm

  dependencies 'install' 'jq' || exit 13

  for _vm in $(acli -o json vm.list | jq -r '.data[] | select(.name | contains("Prism Central")) | .uuid'); do
    log "PC vm.uuid=${_vm}"
    acli vm.off ${_vm} && acli -y vm.delete ${_vm}
  done
}

###################################################################################################################################################
# Routine to deploy PrismProServer
###################################################################################################################################################

function prism_pro_server_deploy() {

### Import Image ###

if (( $(source /etc/profile.d/nutanix_env.sh && acli image.list | grep ${PrismOpsServer} | wc --lines) == 0 )); then
  log "Import ${PrismOpsServer} image from ${QCOW2_REPOS}..."
  acli image.create ${PrismOpsServer} \
    image_type=kDiskImage wait=true \
    container=${STORAGE_IMAGES} source_url="${QCOW2_REPOS}${PrismOpsServer}.qcow2"
else
  log "Image found, assuming ready. Skipping ${PrismOpsServer} import."
fi

### Deploy PrismProServer ###

log "Create ${PrismOpsServer} VM based on ${PrismOpsServer} image"
acli "vm.create ${PrismOpsServer} num_vcpus=2 num_cores_per_vcpu=1 memory=2G"
# vmstat --wide --unit M --active # suggests 2G sufficient, was 4G
#acli "vm.disk_create ${VMNAME} cdrom=true empty=true"
acli "vm.disk_create ${PrismOpsServer} clone_from_image=${PrismOpsServer}"
#acli "vm.nic_create ${PrismOpsServer} network=${NW1_NAME}"
acli "vm.nic_create ${PrismOpsServer} network=${NW1_NAME} ip=${PrismOpsServer_HOST}"

log "Power on ${PrismOpsServer} VM..."
acli "vm.on ${PrismOpsServer}"

}

###################################################################################################################################################
# Routine create the Era Storage container for the Era Bootcamps.
###################################################################################################################################################

function create_era_container() {

  log "Creating Era Storage Container"
  ncli container create name="${STORAGE_ERA}" rf="${ERA_Container_RF}" sp-name="${STORAGE_POOL}" enable-compression=true compression-delay=60

}

#########################################################################################################################################
# Routine to Create Era  Server
#########################################################################################################################################

function deploy_era() {

### Import Image ###

if (( $(source /etc/profile.d/nutanix_env.sh && acli image.list | grep ${ERAServerImage} | wc --lines) == 0 )); then
  log "Import ${ERAServerImage} image from ${QCOW2_REPOS}..."
  acli image.create ${ERAServerImage} \
    image_type=kDiskImage wait=true \
    container=${STORAGE_IMAGES} source_url="${QCOW2_REPOS}${ERAServerImage}"
else
  log "Image found, assuming ready. Skipping ${ERAServerImage} import."
fi

### Deploy PrismProServer ###

log "Create ${ERAServerName} VM based on ${ERAServerImage} image"
acli "vm.create ${ERAServerName} num_vcpus=1 num_cores_per_vcpu=4 memory=4G"
acli "vm.disk_create ${ERAServerName} clone_from_image=${ERAServerImage}"
acli "vm.nic_create ${ERAServerName} network=${NW1_NAME} ip=${ERA_HOST}"

log "Power on ${ERAServerName} VM..."
acli "vm.on ${ERAServerName}"

}


#########################################################################################################################################
# Routine to Create Era Bootcamp PreProvisioned MSSQL Server
#########################################################################################################################################

function deploy_mssql() {

  if (( $(source /etc/profile.d/nutanix_env.sh && acli image.list | grep ${MSSQL_SourceVM_Image} | wc --lines) == 0 )); then
    log "Import ${MSSQL_SourceVM_Image} image from ${QCOW2_REPOS}..."

    acli image.create ${MSSQL_SourceVM_Image1} image_type=kDiskImage wait=true container=${STORAGE_ERA} source_url="${QCOW2_REPOS}era/SQLServer/${MSSQL_SourceVM_Image1}.qcow2"
    acli image.create ${MSSQL_SourceVM_Image2} image_type=kDiskImage wait=true container=${STORAGE_ERA} source_url="${QCOW2_REPOS}era/SQLServer/${MSSQL_SourceVM_Image2}.qcow2"
  else
    log "Image found, assuming ready. Skipping ${MSSQL_SourceVM} import."
  fi

  for _user in "${USERS[@]}" ; do

  SourceVM="${_user}_${MSSQL_SourceVM}"

  echo "## ${SourceVM} Creation_INPROGRESS ##"
  acli "vm.create ${SourceVM} memory=2046M num_cores_per_vcpu=1 num_vcpus=2"
  acli "vm.disk_create ${SourceVM} clone_from_image=${MSSQL_SourceVM_Image1}"
  acli "vm.disk_create ${SourceVM} clone_from_image=${MSSQL_SourceVM_Image2}"
  acli "vm.nic_create ${SourceVM} network=${NW1_NAME}"
  echo "## ${SourceVM} - Powering On ##"
  acli "vm.on ${SourceVM}"
  echo "## ${SourceVM} Creation_COMPLETE ##"

  done

}

#########################################################################################################################################
# Routine to Create Era Bootcamp PreProvisioned Oracle Server
#########################################################################################################################################

function deploy_oracle_12c() {

  if (( $(source /etc/profile.d/nutanix_env.sh && acli image.list | grep ${Oracle_12c_SourceVM_BootImage} | wc --lines) == 0 )); then
    log "Import ${Oracle_12c_SourceVM_BootImage} image from ${QCOW2_REPOS}..."
    acli image.create ${Oracle_12c_SourceVM_BootImage} image_type=kDiskImage wait=true container=${STORAGE_ERA} source_url="${QCOW2_REPOS}era/oracle12cSIHA/${Oracle_12c_SourceVM_BootImage}.qcow2"
    acli image.create ${Oracle_12c_SourceVM_Image1} image_type=kDiskImage wait=true container=${STORAGE_ERA} source_url="${QCOW2_REPOS}era/oracle12cSIHA/${Oracle_12c_SourceVM_Image1}.qcow2"
    acli image.create ${Oracle_12c_SourceVM_Image2} image_type=kDiskImage wait=true container=${STORAGE_ERA} source_url="${QCOW2_REPOS}era/oracle12cSIHA/${Oracle_12c_SourceVM_Image2}.qcow2"
    acli image.create ${Oracle_12c_SourceVM_Image3} image_type=kDiskImage wait=true container=${STORAGE_ERA} source_url="${QCOW2_REPOS}era/oracle12cSIHA/${Oracle_12c_SourceVM_Image3}.qcow2"
    acli image.create ${Oracle_12c_SourceVM_Image4} image_type=kDiskImage wait=true container=${STORAGE_ERA} source_url="${QCOW2_REPOS}era/oracle12cSIHA/${Oracle_12c_SourceVM_Image4}.qcow2"
    acli image.create ${Oracle_12c_SourceVM_Image5} image_type=kDiskImage wait=true container=${STORAGE_ERA} source_url="${QCOW2_REPOS}era/oracle12cSIHA/${Oracle_12c_SourceVM_Image5}.qcow2"
    acli image.create ${Oracle_12c_SourceVM_Image6} image_type=kDiskImage wait=true container=${STORAGE_ERA} source_url="${QCOW2_REPOS}era/oracle12cSIHA/${Oracle_12c_SourceVM_Image6}.qcow2"
  else
    log "Image found, assuming ready. Skipping ${Oracle_SourceVM} import."
  fi

  for _user in "${USERS[@]}" ; do

  SourceVM="${_user}_${Oracle_12c_SourceVM}"

  echo "## ${SourceVM} Creation_INPROGRESS ##"
  acli "vm.create ${SourceVM} memory=4G num_cores_per_vcpu=2 num_vcpus=2"
  acli "vm.disk_create ${SourceVM} clone_from_image=${Oracle_12c_SourceVM_BootImage}"
  acli "vm.disk_create ${SourceVM} clone_from_image=${Oracle_12c_SourceVM_Image1}"
  acli "vm.disk_create ${SourceVM}clone_from_image=${Oracle_12c_SourceVM_Image2}"
  acli "vm.disk_create ${SourceVM}clone_from_image=${Oracle_12c_SourceVM_Image3}"
  acli "vm.disk_create ${SourceVM} clone_from_image=${Oracle_12c_SourceVM_Image4}"
  acli "vm.disk_create ${SourceVM} clone_from_image=${Oracle_12c_SourceVM_Image5}"
  acli "vm.disk_create ${SourceVM} clone_from_image=${Oracle_12c_SourceVM_Image6}"
  acli "vm.nic_create ${SourceVM} network=${NW1_NAME}"
  echo "## ${SourceVM} - Powering On ##"
  acli "vm.on ${SourceVM}"
  echo "### ${SourceVM} Creation_COMPLETE ##"

  done

}

#########################################################################################################################################
# Routine to Upload Era Bootcamp Patch images for Oracle
#########################################################################################################################################

function deploy_oracle_19c() {

  if (( $(source /etc/profile.d/nutanix_env.sh && acli image.list | grep ${Oracle_19c_SourceVM_BootImage} | wc --lines) == 0 )); then
    log "Import ${Oracle_19c_SourceVM_BootImage} image from ${QCOW2_REPOS}..."
    acli image.create ${Oracle_19c_SourceVM_BootImage} image_type=kDiskImage wait=true container=${STORAGE_ERA} source_url="${QCOW2_REPOS}era/oracle19cSIHA/${Oracle_19c_SourceVM_BootImage}.qcow2"
    acli image.create ${Oracle_19c_SourceVM_Image1} image_type=kDiskImage wait=true container=${STORAGE_ERA} source_url="${QCOW2_REPOS}era/oracle19cSIHA/${Oracle_19c_SourceVM_Image1}.qcow2"
    acli image.create ${Oracle_19c_SourceVM_Image2} image_type=kDiskImage wait=true container=${STORAGE_ERA} source_url="${QCOW2_REPOS}era/oracle19cSIHA/${Oracle_19c_SourceVM_Image2}.qcow2"
    acli image.create ${Oracle_19c_SourceVM_Image3} image_type=kDiskImage wait=true container=${STORAGE_ERA} source_url="${QCOW2_REPOS}era/oracle19cSIHA/${Oracle_19c_SourceVM_Image3}.qcow2"
    acli image.create ${Oracle_19c_SourceVM_Image4} image_type=kDiskImage wait=true container=${STORAGE_ERA} source_url="${QCOW2_REPOS}era/oracle19cSIHA/${Oracle_19c_SourceVM_Image4}.qcow2"
    acli image.create ${Oracle_19c_SourceVM_Image5} image_type=kDiskImage wait=true container=${STORAGE_ERA} source_url="${QCOW2_REPOS}era/oracle19cSIHA/${Oracle_19c_SourceVM_Image5}.qcow2"
    acli image.create ${Oracle_19c_SourceVM_Image6} image_type=kDiskImage wait=true container=${STORAGE_ERA} source_url="${QCOW2_REPOS}era/oracle19cSIHA/${Oracle_19c_SourceVM_Image6}.qcow2"
    acli image.create ${Oracle_19c_SourceVM_Image7} image_type=kDiskImage wait=true container=${STORAGE_ERA} source_url="${QCOW2_REPOS}era/oracle19cSIHA/${Oracle_19c_SourceVM_Image7}.qcow2"
    acli image.create ${Oracle_19c_SourceVM_Image8} image_type=kDiskImage wait=true container=${STORAGE_ERA} source_url="${QCOW2_REPOS}era/oracle19cSIHA/${Oracle_19c_SourceVM_Image8}.qcow2"
    acli image.create ${Oracle_19c_SourceVM_Image9} image_type=kDiskImage wait=true container=${STORAGE_ERA} source_url="${QCOW2_REPOS}era/oracle19cSIHA/${Oracle_19c_SourceVM_Image9}.qcow2"
  else
    log "Image found, assuming ready. Skipping ${Oracle_19c_SourceVM_BootImage} import."
  fi

  for _user in "${USERS[@]}" ; do

  SourceVM="${_user}_${Oracle_19c_SourceVM}"

  echo "## ${SourceVM} Creation_INPROGRESS ##"
  acli "vm.create ${SourceVM} memory=8G num_cores_per_vcpu=1 num_vcpus=2"
  acli "vm.disk_create ${SourceVM} clone_from_image=${Oracle_19c_SourceVM_BootImage}"
  acli "vm.disk_create ${SourceVM} clone_from_image=${Oracle_19c_SourceVM_Image1}"
  acli "vm.disk_create ${SourceVM} clone_from_image=${Oracle_19c_SourceVM_Image2}"
  acli "vm.disk_create ${SourceVM} clone_from_image=${Oracle_19c_SourceVM_Image3}"
  acli "vm.disk_create ${SourceVM} clone_from_image=${Oracle_19c_SourceVM_Image4}"
  acli "vm.disk_create ${SourceVM} clone_from_image=${Oracle_19c_SourceVM_Image5}"
  acli "vm.disk_create ${SourceVM} clone_from_image=${Oracle_19c_SourceVM_Image6}"
  acli "vm.disk_create ${SourceVM} clone_from_image=${Oracle_19c_SourceVM_Image7}"
  acli "vm.disk_create ${SourceVM} clone_from_image=${Oracle_19c_SourceVM_Image8}"
  acli "vm.disk_create ${SourceVM} clone_from_image=${Oracle_19c_SourceVM_Image9}"
  acli "vm.nic_create ${SourceVM} network=${NW1_NAME}"
  echo "## ${SourceVM} - Powering On ##"
  acli "vm.on ${SourceVM}"
  echo "### ${SourceVM} Creation_COMPLETE ##"

  done

}

###################################################################################################################################################
# Routine to deploy the Peer Management Center
###################################################################################################################################################
# MTM TODO When integrating with Nutanix scripts, need to change echo to log and put quotes around text after all acli commands
function deploy_peer_mgmt_server() {

  if (( $(source /etc/profile.d/nutanix_env.sh && acli image.list | grep ${PeerMgmtServer} | wc --lines) == 0 )); then
    log "Import ${PeerMgmtServer} image from ${QCOW2_REPOS}..."
    acli image.create ${PeerMgmtServer} \
      image_type=kDiskImage wait=true \
      container=${STORAGE_IMAGES} source_url="${QCOW2_REPOS}peer/${PeerMgmtServer}.qcow2"
  else
    log "Image found, assuming ready. Skipping ${PeerMgmtServer} import."
  fi
  echo "Creating temp folder and applying perms..."
  mkdir /home/nutanix/peer_staging/
  VMNAME=$1
  ### Get sysyprep config file ready ###
  echo "${VMNAME} - Prepping sysprep config..."
  wget http://10.42.194.11/workshop_staging/peer/unattend-pmc.xml -P /home/nutanix/peer_staging/
  mv /home/nutanix/peer_staging/unattend-pmc.xml /home/nutanix/peer_staging/unattend_${VMNAME}.xml
  chmod 777 /home/nutanix/peer_staging/unattend_${VMNAME}.xml
  sed -i "s/<ComputerName>.*<\/ComputerName>/<ComputerName>${VMNAME}<\/ComputerName>/g" /home/nutanix/peer_staging/unattend_${VMNAME}.xml
  ### Deploy PMC Server ###
  echo "${VMNAME} - Deploying VM..."
  #log "Create ${VMNAME} VM based on ${IMAGENAME} image"
  acli "uhura.vm.create_with_customize ${VMNAME} num_vcpus=2 num_cores_per_vcpu=2 memory=4G sysprep_config_path=file:///home/nutanix/peer_staging/unattend_${VMNAME}.xml"
  acli "vm.disk_create ${VMNAME} clone_from_image=${PeerMgmtServer}"
  # MTM TODO replace net1 with appropriate variable
  acli "vm.nic_create ${VMNAME} network=${NW1_NAME}"
  #log "Power on ${VMNAME} VM..."
  echo "${VMNAME} - Powering on..."
  acli "vm.on ${VMNAME}"
  echo "${VMNAME} - Deployed."
}

###################################################################################################################################################
# Routine to deploy a Peer Agent
###################################################################################################################################################
# MTM TODO When integrating with Nutanix scripts, need to change echo to log and put quotes around text after all acli commands
function deploy_peer_agent_server() {

  if (( $(source /etc/profile.d/nutanix_env.sh && acli image.list | grep ${PeerAgentServer} | wc --lines) == 0 )); then
    log "Import ${PeerAgentServer} image from ${QCOW2_REPOS}..."
    acli image.create ${PeerAgentServer} \
      image_type=kDiskImage wait=true \
      container=${STORAGE_IMAGES} source_url="${QCOW2_REPOS}peer/${PeerAgentServer}.qcow2"
  else
    log "Image found, assuming ready. Skipping ${PeerAgentServer} import."
  fi
  VMNAME=$1
  ### Get sysyprep config file ready ###
  echo "${VMNAME} - Prepping sysprep config..."
  wget http://10.42.194.11/workshop_staging/peer/unattend-agent.xml -P /home/nutanix/peer_staging/
  mv /home/nutanix/peer_staging/unattend-agent.xml /home/nutanix/peer_staging/unattend_${VMNAME}.xml
  chmod 777 /home/nutanix/peer_staging/unattend_${VMNAME}.xml
  sed -i "s/<ComputerName>.*<\/ComputerName>/<ComputerName>${VMNAME}<\/ComputerName>/g" /home/nutanix/peer_staging/unattend_${VMNAME}.xml
  ### Deploy Agent Server ###
  echo "${VMNAME} - Deploying VM..."
  #log "Create ${VMNAME} VM based on ${IMAGENAME} image"
  acli "uhura.vm.create_with_customize ${VMNAME} num_vcpus=2 num_cores_per_vcpu=2 memory=4G sysprep_config_path=file:///home/nutanix/peer_staging/unattend_${VMNAME}.xml"
  acli "vm.disk_create ${VMNAME} clone_from_image=${PeerAgentServer}"
  # MTM TODO replace net1 with appropriate variable
  acli "vm.nic_create ${VMNAME} network=${NW1_NAME}"
  #log "Power on ${VMNAME} VM..."
  echo "${VMNAME} - Powering on..."
  acli "vm.on ${VMNAME}"
  echo "${VMNAME} - Deployed."
}