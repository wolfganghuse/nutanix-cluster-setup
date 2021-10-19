#!/usr/bin/env bash
# -x
# Dependencies: curl, ncli, nuclei, jq

###############################################################################################################################################################################
# 12th of April 2019 - Willem Essenstam
# Added a "-d" character in the flow_enable so the command would run.
# Changed the Karbon Eanable function so it also checks that Karbon has been enabled. Some small typos changed so the Karbon part should work
#
# 31-05-2019 - Willem Essenstam
# Added the download bits for the Centos Image for Karbon
###############################################################################################################################################################################

###############################################################################################################################################################################
# Routine to mark PC has finished staging
###############################################################################################################################################################################

function finish_staging() {
  log "Staging is complete. Writing to .staging_complete"
  touch .staging_complete
  date >> .staging_complete
}


###############################################################################################################################################################################
# Routine to enable Flow
###############################################################################################################################################################################

function flow_enable() {
  local _attempts=30
  local _loops=0
  local _sleep=60
  local CURL_HTTP_OPTS=' --max-time 25 --silent --header Content-Type:application/json --header Accept:application/json  --insecure '
  local _url_flow='https://localhost:9440/api/nutanix/v3/services/microseg'

  # Create the JSON payload
  _json_data='{"state":"ENABLE"}'

  log "Enable Nutanix Flow..."

  # Enabling Flow and put the task id in a variable
  _task_id=$(curl -X POST -d $_json_data $CURL_HTTP_OPTS --user ${PRISM_ADMIN}:${PE_PASSWORD} $_url_flow | jq '.task_uuid' | tr -d \")

  # Try one more time then fail, but continue
  if [ -z $_task_id ]; then
    log "Flow not yet enabled. Will retry...."
    _task_id=$(curl -X POST $_json_data $CURL_HTTP_OPTS --user ${PRISM_ADMIN}:${PE_PASSWORD} $_url_flow | jq '.task_uuid' | tr -d \")

    if [ -z $_task_id ]; then
      log "Flow still not enabled.... ***Not retrying. Please enable via UI.***"
    fi
  else
    loop ${_task_id}
    log "Flow has been Enabled..."
  fi



}



###############################################################################################################################################################################
# Routine to start the LCM Inventory and the update.
###############################################################################################################################################################################

function lcm() {

  local _url_lcm='https://localhost:9440/PrismGateway/services/rest/v1/genesis'
  local _url_progress='https://localhost:9440/api/nutanix/v3/tasks'
  local _url_groups='https://localhost:9440/api/nutanix/v3/groups'
  local CURL_HTTP_OPTS=' --max-time 25 --silent --header Content-Type:application/json --header Accept:application/json  --insecure '

  # Reset the variables we use so we're not adding extra values to the arrays
  unset uuid_arr
  unset version_ar

  # Inventory download/run
  _task_id=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST -d '{"value":"{\".oid\":\"LifeCycleManager\",\".method\":\"lcm_framework_rpc\",\".kwargs\":{\"method_class\":\"LcmFramework\",\"method\":\"perform_inventory\",\"args\":[\"http://download.nutanix.com/lcm/2.0\"]}}"}' ${_url_lcm} | jq '.value' 2>nul | cut -d "\\" -f 4 | tr -d \")

  # If there has been a reply (task_id) then the URL has accepted by PC
  # Changed (()) to [] so it works....
  if [ -z "$_task_id" ]; then
       log "LCM Inventory start has encountered an eror..."
  else
       log "LCM Inventory started.."
       set _loops=0 # Reset the loop counter so we restart the amount of loops we need to run

       # Run the progess checker
       loop

       #################################################################
       # Grab the json from the possible to be updated UUIDs and versions and save local in reply_json.json
       #################################################################

       # Need loop so we can create the full json more dynamical

       # Issue is taht after the LCM inventory the LCM will be updated to a version 2.0 and the API call needs to change!!!
       # We need to figure out if we are running V1 or V2!
       lcm_version=$(curl $CURL_HTTP_OPTS --user $PRISM_ADMIN:$PE_PASSWORD -X POST -d '{"value":"{\".oid\":\"LifeCycleManager\",\".method\":\"lcm_framework_rpc\",\".kwargs\":{\"method_class\":\"LcmFramework\",\"method\":\"get_config\"}}"}'  ${_url_lcm} | jq '.value' | tr -d \\ | sed 's/^"\(.*\)"$/\1/' | sed 's/.return/return/g' | jq '.return.lcm_cpdb_table_def_list.entity' | tr -d \"| grep "lcm_entity_v2" | wc -l)

       if [ $lcm_version -lt 1 ]; then
              log "LCM Version 1 found.."
              # V1: Run the Curl command and save the oputput in a temp file
              curl $CURL_HTTP_OPTS --user $PRISM_ADMIN:$PE_PASSWORD -X POST -d '{"entity_type": "lcm_available_version","grouping_attribute": "entity_uuid","group_member_count": 1000,"group_member_attributes": [{"attribute": "uuid"},{"attribute": "entity_uuid"},{"attribute": "entity_class"},{"attribute": "status"},{"attribute": "version"},{"attribute": "dependencies"},{"attribute": "order"}]}'  $_url_groups > reply_json.json

              # Fill the uuid array with the correct values
              uuid_arr=($(jq '.group_results[].entity_results[].data[] | select (.name=="entity_uuid") | .values[0].values[0]' reply_json.json | sort -u | tr "\"" " " | tr -s " "))

              # Grabbing the versions of the UUID and put them in a versions array
              for uuid in "${uuid_arr[@]}"
              do
                version_ar+=($(jq --arg uuid "$uuid" '.group_results[].entity_results[] | select (.data[].values[].values[0]==$uuid) | select (.data[].name=="version") | .data[].values[].values[0]' reply_json.json | tail -4 | head -n 1 | tr -d \"))
              done
        else
              log "LCM Version 2 found.."

              #''_V2: run the other V2 API call to get the UUIDs of the to be updated software parts
              # Grab the installed version of the software first UUIDs
              curl $CURL_HTTP_OPTS --user $PRISM_ADMIN:$PE_PASSWORD -X POST -d '{"entity_type": "lcm_entity_v2","group_member_count": 500,"group_member_attributes": [{"attribute": "id"}, {"attribute": "uuid"}, {"attribute": "entity_model"}, {"attribute": "version"}, {"attribute": "location_id"}, {"attribute": "entity_class"}, {"attribute": "description"}, {"attribute": "last_updated_time_usecs"}, {"attribute": "request_version"}, {"attribute": "_master_cluster_uuid_"}, {"attribute": "entity_type"}, {"attribute": "single_group_uuid"}],"query_name": "lcm:EntityGroupModel","grouping_attribute": "location_id","filter_criteria": "entity_model!=AOS;entity_model!=NCC;entity_model!=PC;_master_cluster_uuid_==[no_val]"}' $_url_groups > reply_json_uuid.json

              # Fill the uuid array with the correct values
              uuid_arr=($(jq '.group_results[].entity_results[].data[] | select (.name=="uuid") | .values[0].values[0]' reply_json_uuid.json | sort -u | tr "\"" " " | tr -s " "))

              # Grab the available updates from the PC after LCMm has run
              curl $CURL_HTTP_OPTS --user $PRISM_ADMIN:$PE_PASSWORD -X POST -d '{"entity_type": "lcm_available_version_v2","group_member_count": 500,"group_member_attributes": [{"attribute": "uuid"},{"attribute": "entity_uuid"}, {"attribute": "entity_class"}, {"attribute": "status"}, {"attribute": "version"}, {"attribute": "dependencies"},{"attribute": "single_group_uuid"}, {"attribute": "_master_cluster_uuid_"}, {"attribute": "order"}],"query_name": "lcm:VersionModel","filter_criteria": "_master_cluster_uuid_==[no_val]"}' $_url_groups > reply_json_ver.json

              # Grabbing the versions of the UUID and put them in a versions array
              for uuid in "${uuid_arr[@]}"
                do
                  # Get the latest version from the to be updated uuid. Put always a value in the array otherwise we loose/have skewed verrsions to products
                  version=($(jq --arg uuid "$uuid" '.group_results[].entity_results[] | select (.data[].values[].values[]==$uuid) .data[] | select (.name=="version") .values[].values[]' reply_json_ver.json | sort |tail -1 | tr -d \"))
                  # If no version upgrade available add a blank item in the array
                  if [[ -z $version ]]; then
                    version='NA'
                  fi
                  version_ar+=($version)
                done
              # Copy the right info into the to be used array
        fi

       # Set the parameter to create the ugrade plan
       # Create the curl json string '-d blablablablabla' so we can call the string and not the full json data line
       # Begin of the JSON data payload
       _json_data="-d "
       _json_data+="{\"value\":\"{\\\".oid\\\":\\\"LifeCycleManager\\\",\\\".method\\\":\\\"lcm_framework_rpc\\\",\\\".kwargs\\\":{\\\"method_class\\\":\\\"LcmFramework\\\",\\\"method\\\":\\\"generate_plan\\\",\\\"args\\\":[\\\"http://download.nutanix.com/lcm/2.0\\\",["

       # Combine the two created UUID and Version arrays to the full needed data using a loop
       count=0
       while [ $count -lt ${#uuid_arr[@]} ]
       do
          if [[ ${version_ar[$count]} != *"NA"* ]]; then
            _json_data+="[\\\"${uuid_arr[$count]}\\\",\\\"${version_ar[$count]}\\\"],"
            log "Found UUID ${uuid_arr[$count]} and version ${version_ar[$count]}"
          fi
          let count=count+1
        done

       # Remove the last "," as we don't need it.
       _json_data=${_json_data%?};

       # Last part of the JSON data payload
       _json_data+="]]}}\"}"

       # Run the generate plan task
       _task_id=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST $_json_data ${_url_lcm})

       # Notify the log server that the LCM has created a plan
       log "LCM Inventory has created a plan"

       # Reset the loop counter so we restart the amount of loops we need to run
       set _loops=0

       # As the new json for the perform the upgrade only needs to have "generate_plan" changed into "perform_update" we use sed...
       _json_data=$(echo $_json_data | sed -e 's/generate_plan/perform_update/g')


       # Run the upgrade to have the latest versions
       _task_id=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST $_json_data ${_url_lcm} | jq '.value' 2>nul | cut -d "\\" -f 4 | tr -d \")

       # If there has been a reply task_id then the URL has accepted by PC
        if [ -z "$_task_id" ]; then
            # There has been an error!!!
            log "LCM Upgrade has encountered an error!!!!"
        else
            # Notify the logserver that we are starting the LCM Upgrade
            log "LCM Upgrade starting...Process may take up to 45 minutes!!!"

            # Run the progess checker
            loop
        fi
  fi

  # Remove the temp json files as we don't need it anymore
       #rm -rf reply_json.json
       #rm -rf reply_json_ver.json
       #rm -rf reply_json_uuid.json

}

###############################################################################################################################################################################
# Routine to enable Karbon
###############################################################################################################################################################################

function karbon_enable() {
  local CURL_HTTP_OPTS=' --max-time 25 --silent --header Content-Type:application/json --header Accept:application/json  --insecure '
  local _loop=0
  local _json_data_set_enable="{\"value\":\"{\\\".oid\\\":\\\"ClusterManager\\\",\\\".method\\\":\\\"enable_service_with_prechecks\\\",\\\".kwargs\\\":{\\\"service_list_json\\\":\\\"{\\\\\\\"service_list\\\\\\\":[\\\\\\\"KarbonUIService\\\\\\\",\\\\\\\"KarbonCoreService\\\\\\\"]}\\\"}}\"}"
  local _json_is_enable="{\"value\":\"{\\\".oid\\\":\\\"ClusterManager\\\",\\\".method\\\":\\\"is_service_enabled\\\",\\\".kwargs\\\":{\\\"service_name\\\":\\\"KarbonUIService\\\"}}\"} "
  local _httpURL="https://localhost:9440/PrismGateway/services/rest/v1/genesis"

  # Start the enablement process
  _response=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST -d $_json_data_set_enable ${_httpURL}| grep "[true, null]" | wc -l)

  # Check if we got a "1" back (start sequence received). If not, retry. If yes, check if enabled...
  if [[ $_response -eq 1 ]]; then
    # Check if Karbon has been enabled
    _response=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST -d $_json_is_enable ${_httpURL}| grep "[true, null]" | wc -l)
    while [ $_response -ne 1 ]; do
        _response=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST -d $_json_is_enable ${_httpURL}| grep "[true, null]" | wc -l)
    done
    log "Karbon has been enabled."
  else
    log "Retrying to enable Karbon one more time."
    _response=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST -d $_json_data_set_enable ${_httpURL}| grep "[true, null]" | wc -l)
    if [[ $_response -eq 1 ]]; then
      _response=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST -d $_json_is_enable ${_httpURL}| grep "[true, null]" | wc -l)
      if [ $_response -lt 1 ]; then
        log "Karbon isn't enabled. Please use the UI to enable it."
      else
        log "Karbon has been enabled."
      fi
    fi
  fi
}

###############################################################################################################################################################################
# Download Karbon CentOS Image
###############################################################################################################################################################################

function karbon_image_download() {
  local CURL_HTTP_OPTS=' --max-time 25 --silent --header Content-Type:application/json --header Accept:application/json  --insecure '
  local _loop=0
  local _cookies=''NTNX_IGW_SESSION': resp.cookies['NTNX_IGW_SESSION']'
  local _startDownload="https://localhost:9440/karbon/acs/image/download"
  local _getuuidDownload="https://localhost:9440/karbon/acs/image/list"

  # Create the Basic Authentication using base6 commands
  _auth=$(echo "admin:${PE_PASSWORD}" | base64)

  # Call the UUID URL so we have the right UUID for the image
  uuid=$(curl -X GET -H "X-NTNX-AUTH: Basic ${_auth}" https://localhost:9440/karbon/acs/image/list $CURL_HTTP_OPTS | jq '.[0].uuid' | tr -d \/\")
  log "UUID for The Karbon image is: $uuid"

  # Use the UUID to download the image
  response=$(curl -X POST ${_startDownload} -d "{\"uuid\":\"${uuid}\"}" -H "X-NTNX-AUTH: Basic ${_auth}" ${CURL_HTTP_OPTS})

  if [ -z $response ]; then
    log "Download of the CentOS image for Karbon has not been started. Trying one more time..."
    response=$(curl -X POST ${_startDownload} -d "{\"uuid\":\"${uuid}\"}" -H "X-NTNX-AUTH: Basic ${_auth}" ${CURL_HTTP_OPTS})
    if [ -z $response ]; then
      log "Download of CentOS image for Karbon failed... Please run manually."
    fi
  else
    log "Download of CentOS image for Karbon has started..."
  fi
}

###############################################################################################################################################################################
# Routine to enable Objects
###############################################################################################################################################################################

function objects_enable() {
  local CURL_HTTP_OPTS=' --max-time 25 --silent --header Content-Type:application/json --header Accept:application/json  --insecure '
  local _loops=0
  local _json_data_set_enable="{\"state\":\"ENABLE\"}"
  local _json_data_check="{\"entity_type\":\"objectstore\"}"
  local _httpURL_check="https://localhost:9440/oss/api/nutanix/v3/groups"
  local _httpURL="https://localhost:9440/api/nutanix/v3/services/oss"
  local _maxtries=30

  # Start the enablement process
  _response=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST -d $_json_data_set_enable ${_httpURL})
  log "Enabling Objects....."

  # The response should be a Task UUID
  if [[ ! -z $_response ]]; then
    # Check if OSS has been enabled
    _response=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST -d $_json_data_check ${_httpURL_check}| grep "objectstore" | wc -l)
    while [ $_response -ne 1 ]; do
        _response=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST -d $_json_data_check ${_httpURL_check}| grep "objectstore" | wc -l)
        if [[ $loops -ne 30 ]]; then
          sleep 10
          (( _loops++ ))
        else
          log "Objects isn't enabled. Please use the UI to enable it."
          break
        fi
    done
    log "Objects has been enabled."
  else
    log "Objects isn't enabled. Please use the UI to enable it."
  fi
}

###############################################################################################################################################################################
# Create an object store called ntnx_object.ntnxlab.local
###############################################################################################################################################################################

function object_store() {
    local _attempts=30
    local _loops=0
    local _sleep=60
    local CURL_HTTP_OPTS=' --max-time 25 --silent --header Content-Type:application/json --header Accept:application/json  --insecure '
    local _url_network='https://localhost:9440/api/nutanix/v3/subnets/list'
    local _url_oss='https://localhost:9440/oss/api/nutanix/v3/objectstores'
    local _url_oss_check='https://localhost:9440/oss/api/nutanix/v3/objectstores/list'


    # Enable Dark Site Repo and wait 3 seconds
    #mspctl airgap --enable --lcm-server=${OBJECTS_OFFLINE_REPO}
    #sleep 3
    # Confirm airgap is enabled
    #_response=$(mspctl airgap --status | grep "\"enable\":true" | wc -l)

    #if [ $_response -eq 1 ]; then
    #  log "Objects dark site staging successfully enabled. Response is $_response. "
    #else
    #  log "Objects failed to enable dark site staging. Will use standard WAN download (this will take longer). Response is $_response."
    #fi

    # Payload for the _json_data
    _json_data='{"kind":"subnet"}'

    # Get the json data and split into CLUSTER_UUID and Primary_Network_UUID
    CLUSTER_UUID=$(curl -X POST -d $_json_data $CURL_HTTP_OPTS --user ${PRISM_ADMIN}:${PE_PASSWORD} $_url_network | jq '.entities[].spec | select (.name=="Primary") | .cluster_reference.uuid' | tr -d \")
    echo ${CLUSTER_UUID}

    PRIM_NETWORK_UUID=$(curl -X POST -d $_json_data $CURL_HTTP_OPTS --user ${PRISM_ADMIN}:${PE_PASSWORD} $_url_network | jq '.entities[] | select (.spec.name=="Primary") | .metadata.uuid' | tr -d \")
    echo ${PRIM_NETWORK_UUID}

    echo "BUCKETS_DNS_IP: ${BUCKETS_DNS_IP}, BUCKETS_VIP: ${BUCKETS_VIP}, OBJECTS_NW_START: ${OBJECTS_NW_START}, OBJECTS_NW_END: ${OBJECTS_NW_END}"
    sleep 5
    _json_data_oss='{"api_version":"3.0","metadata":{"kind":"objectstore"},"spec":{"name":"ntnx-objects","description":"NTNXLAB","resources":{"domain":"ntnxlab.local","cluster_reference":{"kind":"cluster","uuid":"'
    _json_data_oss+=${CLUSTER_UUID}
    _json_data_oss+='"},"buckets_infra_network_dns":"'
    _json_data_oss+=${BUCKETS_DNS_IP}
    _json_data_oss+='","buckets_infra_network_vip":"'
    _json_data_oss+=${BUCKETS_VIP}
    _json_data_oss+='","buckets_infra_network_reference":{"kind":"subnet","uuid":"'
    _json_data_oss+=${PRIM_NETWORK_UUID}
    _json_data_oss+='"},"client_access_network_reference":{"kind":"subnet","uuid":"'
    _json_data_oss+=${PRIM_NETWORK_UUID}
    _json_data_oss+='"},"aggregate_resources":{"total_vcpu_count":10,"total_memory_size_mib":32768,"total_capacity_gib":51200},"client_access_network_ipv4_range":{"ipv4_start":"'
    _json_data_oss+=${OBJECTS_NW_START}
    _json_data_oss+='","ipv4_end":"'
    _json_data_oss+=${OBJECTS_NW_END}
    _json_data_oss+='"}}}}'

    # Set the right VLAN dynamically so we are configuring in the right network
    _json_data_oss=${_json_data_oss//VLANX/${VLAN}}
    _json_data_oss=${_json_data_oss//NETWORKX/${NETWORK}}

    #curl -X POST -d $_json_data_oss $CURL_HTTP_OPTS --user ${PRISM_ADMIN}:${PE_PASSWORD} $_url_oss
     _createresponse=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST -d $_json_data_oss ${_url_oss})
      log "Creating Object Store....."

  # The response should be a Task UUID
  if [[ ! -z $_createresponse ]]; then
    # Check if Object store is deployed
    _response=$(curl ${CURL_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X GET ${_url_oss_check}| grep "ntnx-objects" | wc -l)
    while [ $_response -ne 1 ]; do
        log "Object Store not yet created. $_loops/$_attempts... sleeping 10 seconds"
        _response=$(curl ${CURL_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X GET ${_url_oss_check}| grep "ntnx-objects" | wc -l)
        if [[ $_loops -ne 30 ]]; then
          _createresponse=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST -d $_json_data_oss ${_url_oss})
          sleep 10
          (( _loops++ ))
        else
          log "Objects store ntnx-objects not created. Please use the UI to create it."
          break
        fi
    done
    log "Objects store been created."
  else
    log "Objects store could not be created. Please use the UI to create it."
  fi

}


###############################################################################################################################################################################
# Routine for PC_Admin
###############################################################################################################################################################################

function pc_admin() {
  local  _http_body
  local       _test
  local _admin_user='nathan'

  _http_body=$(cat <<EOF
  {"profile":{
    "username":"${_admin_user}",
    "firstName":"Nathan",
    "lastName":"Cox",
    "emailId":"${EMAIL}",
    "password":"${PE_PASSWORD}",
    "locale":"en-US"},"enabled":false,"roles":[]}
EOF
  )
  _test=$(curl ${CURL_HTTP_OPTS} \
    --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST --data "${_http_body}" \
    https://localhost:9440/PrismGateway/services/rest/v1/users)
  log "create.user=${_admin_user}=|${_test}|"

  _http_body='["ROLE_USER_ADMIN","ROLE_MULTICLUSTER_ADMIN"]'
       _test=$(curl ${CURL_HTTP_OPTS} \
    --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST --data "${_http_body}" \
    https://localhost:9440/PrismGateway/services/rest/v1/users/${_admin_user}/roles)
  log "add.roles ${_http_body}=|${_test}|"
}

###############################################################################################################################################################################
# Routine set PC authentication to use the AD as well
###############################################################################################################################################################################
function pc_auth() {
  # TODO:190 configure case for each authentication server type?
  local      _group
  local  _http_body
  local _pc_version
  local       _test
  local CURL_HTTP_OPTS=" --max-time 25 --silent --header Content-Type:application/json --header Accept:application/json  --insecure "

  # TODO:50 FUTURE: pass AUTH_SERVER argument

set -x

  log "Add Directory ${AUTH_DOMAIN}"
  _http_body=$(cat <<EOF
{
  "api_version": "3.1",
    "metadata": {
        "kind": "directory_service"
    },
  "spec": {
    "name": "${AUTH_DOMAIN}",
    "resources": {
      "url": "ldap://${AUTH_HOST}:${LDAP_PORT}",
      "directory_type": "ACTIVE_DIRECTORY",
      "domain_name": "${AUTH_FQDN}",
      "service_account": {
        "username": "${AUTH_ADMIN_USER}",
        "password": "${AUTH_ADMIN_PASS}"
      }
    }
  }
}
EOF
  )

  _task_id=$(curl ${CURL_POST_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST --data "${_http_body}" https://localhost:9440/api/nutanix/v3/directory_services | jq -r '.status.execution_context.task_uuid' | tr -d \")

  #log "Task uuid for the Auth Source Create is " $_task_id " ....."

  #if [ -z "$_task_id" ]; then
  #     log "Auth Source Create has encountered an error..."
  #else
  #     log "Auth Source Create started.."
  #     set _loops=0 # Reset the loop counter so we restart the amount of loops we need to run
       # Run the progess checker
  #     loop
  #fi

  #log "directories: _task_id=|${_task_id}|_http_body=|${_http_body}|"

  sleep 60

  log "Add Role Mappings to Groups for PC logins (not projects, which are separate)..."

    _http_body=$(cat <<EOF
{
    "directoryName": "${AUTH_DOMAIN}",
    "role": "ROLE_CLUSTER_ADMIN",
    "entityType": "GROUP",
    "entityValues": [
        "${AUTH_ADMIN_GROUP}"
    ]
}
EOF
    )

  _task_id=$(curl ${CURL_POST_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST --data "${_http_body}" https://localhost:9440/PrismGateway/services/rest/v1/authconfig/directories/${AUTH_DOMAIN}/role_mappings?entityType=GROUP&role=ROLE_CLUSTER_ADMIN)

  #log "Task uuid for the Auth Source Create is " $_task_id " ....."

  #if [ -z "$_task_id" ]; then
  #     log "Role Create has encountered an error..."
  #else
  #     log "Role Create started.."
  #     set _loops=0 # Reset the loop counter so we restart the amount of loops we need to run
  #     # Run the progess checker
  #     loop
  #fi

  log "Cluster Admin=${AUTH_ADMIN_GROUP}, _task_id=|${_task_id}|_http_body=|${_http_body}| "

set +x

}

###################################################################################################################################################
# Routine to import the images into PC
###################################################################################################################################################

function pc_cluster_img_import() {
  local _http_body
  local      _test
  local      _uuid
  local CURL_HTTP_OPTS=" --max-time 25 --silent --header Content-Type:application/json --header Accept:application/json  --insecure "

  log "Cluster Name |${CLUSTER_NAME}|"

  ## Get Cluster UUID ##
  log "-------------------------------------"
  log "Get Cluster UUID"

  _cluster_uuid=$(curl ${CURL_HTTP_OPTS} -X POST 'https://localhost:9440/api/nutanix/v3/clusters/list' --user ${PRISM_ADMIN}:${PE_PASSWORD} --data '{}' | jq --arg CLUSTER "${CLUSTER_NAME}" '.entities[]|select (.status.name==$CLUSTER)| .metadata.uuid' | tr -d \")

  log "Cluster UUID |${_cluster_uuid}|"

_http_body=$(cat <<EOF
{
     "image_reference_list":[],
     "cluster_reference":{
       "uuid":"${_cluster_uuid}",
       "kind":"cluster"}
}
EOF
  )

  _test=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST --data "${_http_body}" https://localhost:9440/api/nutanix/v3/images/migrate)
  log "Image Migration = |${_test}|"
}

###############################################################################################################################################################################
# Routine to add dns servers
###############################################################################################################################################################################

function pc_dns_add() {
  local _dns_server
  local       _test

  for _dns_server in $(echo "${DNS_SERVERS}" | sed -e 's/,/ /'); do
    _test=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST --data "[\"$_dns_server\"]" \
      https://localhost:9440/PrismGateway/services/rest/v1/cluster/name_servers/add_list)
    log "name_servers/add_list |${_dns_server}| _test=|${_test}|"
  done
}

###############################################################################################################################################################################
# Routine to setup the initial steps for PC; NTP, EULA and Pulse
###############################################################################################################################################################################

function pc_init() {
  # TODO:130 pc_init: NCLI, type 'cluster get-smtp-server' config for idempotency?
  local _test

  log "Configure NTP@PC"
  ncli cluster add-to-ntp-servers \
    servers=0.us.pool.ntp.org,1.us.pool.ntp.org,2.us.pool.ntp.org,3.us.pool.ntp.org

  log "Validate EULA@PC"
  _test=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST -d '{
      "username": "SE",
      "companyName": "NTNX",
      "jobTitle": "SE"
  }' https://localhost:9440/PrismGateway/services/rest/v1/eulas/accept)
  log "EULA _test=|${_test}|"

  log "Disable Pulse@PC"
  _test=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X PUT -d '{
      "emailContactList":null,
      "enable":false,
      "verbosityType":null,
      "enableDefaultNutanixEmail":false,
      "defaultNutanixEmail":null,
      "nosVersion":null,
      "isPulsePromptNeeded":false,
      "remindLater":null
  }' https://localhost:9440/PrismGateway/services/rest/v1/pulse)
  log "PULSE _test=|${_test}|"
}

###############################################################################################################################################################################
# Routine to setup the SMTP server in PC
###############################################################################################################################################################################

function pc_smtp() {
  log "Configure SMTP@PC"
  local _sleep=5

  args_required 'SMTP_SERVER_ADDRESS SMTP_SERVER_FROM SMTP_SERVER_PORT'
  ncli cluster set-smtp-server port=${SMTP_SERVER_PORT} \
    address=${SMTP_SERVER_ADDRESS} from-email-address=${SMTP_SERVER_FROM}
  #log "sleep ${_sleep}..."; sleep ${_sleep}
  #log $(ncli cluster get-smtp-server | grep Status | grep success)

  # shellcheck disable=2153
  ncli cluster send-test-email recipient="${EMAIL}" \
    subject="pc_smtp https://${PRISM_ADMIN}:${PE_PASSWORD}@${PC_HOST}:9440 Testing."
  # local _test=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST -d '{
  #   "address":"${SMTP_SERVER_ADDRESS}","port":"${SMTP_SERVER_PORT}","username":null,"password":null,"secureMode":"NONE","fromEmailAddress":"${SMTP_SERVER_FROM}","emailStatus":null}' \
  #   https://localhost:9440/PrismGateway/services/rest/v1/cluster/smtp)
  # log "_test=|${_test}|"
}

###############################################################################################################################################################################
# Routine to change the PC admin password
###############################################################################################################################################################################

function pc_passwd() {
  args_required 'PRISM_ADMIN PE_PASSWORD'

  log "Reset PC password to PE password, must be done by ncli@PC, not API or on PE"
  ncli user reset-password user-name=${PRISM_ADMIN} password=${PE_PASSWORD}
  if (( $? > 0 )); then
   log "Warning: password not reset: $?."# exit 10
  fi
  # TOFIX: nutanix@PC Linux account password change as well?

  # local _old_pw='nutanix/4u'
  # local _http_body=$(cat <<EOF
  # {"oldPassword": "${_old_pw}","newPassword": "${PE_PASSWORD}"}
  # EOF
  # )
  # local _test
  # _test=$(curl ${CURL_HTTP_OPTS} --user "${PRISM_ADMIN}:${_old_pw}" -X POST --data "${_http_body}" \
  #     https://localhost:9440/PrismGateway/services/rest/v1/utils/change_default_system_password)
  # log "cURL reset password _test=${_test}"
}




###############################################################################################################################################################################
# Seed PC data for Prism Pro Labs
###############################################################################################################################################################################

function seedPC() {
    local _test
    local _setup

    _test=$(curl -L ${PC_DATA} -o /home/nutanix/${SeedPC})
    log "Pulling Prism Data| PC_DATA ${PC_DATA}|${_test}"
    unzip /home/nutanix/${SeedPC}
    pushd /home/nutanix/lab/

    #_setup=$(/home/nutanix/lab/initialize_lab.sh ${PC_HOST} > /dev/null 2>&1)
    _setup=$(/home/nutanix/lab/initialize_lab.sh ${PC_HOST} admin ${PE_PASSWORD} ${PE_HOST} nutanix ${PE_PASSWORD} > /dev/null 2>&1)
    log "Running Setup Script|$_setup"

    popd
}

###############################################################################################################################################################################
# Routine to setp up the SSP authentication to use the AutoDC server
###############################################################################################################################################################################

function ssp_auth() {
  args_required 'AUTH_SERVER AUTH_HOST AUTH_ADMIN_USER AUTH_ADMIN_PASS'

  local   _http_body
  local   _ldap_name
  local   _ldap_uuid
  local _ssp_connect

  log "Find ${AUTH_SERVER} uuid"
  _ldap_uuid=$(PATH=${PATH}:${HOME}; curl ${CURL_POST_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} --data '{ "kind": "directory_service" }' 'https://localhost:9440/api/nutanix/v3/directory_services/list' | jq -r .entities[0].metadata.uuid)
  log "_ldap_uuid=|${_ldap_uuid}|"

  # TODO:110 get directory service name _ldap_name
  _ldap_name=${AUTH_DOMAIN}
  # TODO:140 bats? test ldap connection

  log "Connect SSP Authentication (spec-ssp-authrole.json)..."
  _http_body=$(cat <<EOF
  {
    "spec": {
      "name": "${AUTH_SERVER}",
      "resources": {
        "admin_group_reference_list": [
          {
            "name": "cn=ssp developers,cn=users,dc=ntnxlab,dc=local",
            "uuid": "3933a846-fe73-4387-bb39-7d66f222c844",
            "kind": "user_group"
          }
        ],
        "service_account": {
          "username": "${AUTH_ADMIN_USER}",
          "password": "${AUTH_ADMIN_PASS}"
        },
        "url": "ldaps://${AUTH_HOST}/",
        "directory_type": "ACTIVE_DIRECTORY",
        "admin_user_reference_list": [],
        "domain_name": "${AUTH_DOMAIN}"
      }
    },
    "metadata": {
      "kind": "directory_service",
      "spec_version": 0,
      "uuid": "${_ldap_uuid}",
      "categories": {}
    },
    "api_version": "3.1.0"
  }
EOF
  )
  _ssp_connect=$(curl ${CURL_POST_OPTS} \
    --user ${PRISM_ADMIN}:${PE_PASSWORD} -X PUT --data "${_http_body}" \
    https://localhost:9440/api/nutanix/v3/directory_services/${_ldap_uuid})
  log "_ssp_connect=|${_ssp_connect}|"

  # TODO:120 SSP Admin assignment, cluster, networks (default project?) = spec-project-config.json
  # PUT https://localhost:9440/api/nutanix/v3/directory_services/9d8c2c33-9d95-438c-a7f4-2187120ae99e = spec-ssp-direcory_service.json
  # TODO:60 FUTURE: use directory_type variable?
  log "Enable SSP Admin Authentication (spec-ssp-direcory_service.json)..."
  _http_body=$(cat <<EOF
  {
    "spec": {
      "name": "${_ldap_name}",
      "resources": {
        "service_account": {
          "username": "${AUTH_ADMIN_USER}@${AUTH_FQDN}",
          "password": "${AUTH_ADMIN_PASS}"
        },
        "url": "ldaps://${AUTH_HOST}/",
        "directory_type": "ACTIVE_DIRECTORY",
        "domain_name": "${AUTH_DOMAIN}"
      }
    },
    "metadata": {
      "kind": "directory_service",
      "spec_version": 0,
      "uuid": "${_ldap_uuid}",
      "categories": {}
    },
    "api_version": "3.1.0"
  }
EOF
  )
  _ssp_connect=$(curl ${CURL_POST_OPTS} \
    --user ${PRISM_ADMIN}:${PE_PASSWORD} -X PUT --data "${_http_body}" \
    https://localhost:9440/api/nutanix/v3/directory_services/${_ldap_uuid})
  log "_ssp_connect=|${_ssp_connect}|"
  # POST https://localhost:9440/api/nutanix/v3/groups = spec-ssp-groups.json
  # TODO:100 can we skip previous step?
  log "Enable SSP Admin Authentication (spec-ssp-groupauth_2.json)..."
  _http_body=$(cat <<EOF
  {
    "spec": {
      "name": "${_ldap_name}",
      "resources": {
        "service_account": {
          "username": "${AUTH_ADMIN_USER}@${AUTH_DOMAIN}",
          "password": "${AUTH_ADMIN_PASS}"
        },
        "url": "ldaps://${AUTH_HOST}/",
        "directory_type": "ACTIVE_DIRECTORY",
        "domain_name": "${AUTH_DOMAIN}"
        "admin_user_reference_list": [],
        "admin_group_reference_list": [
          {
            "kind": "user_group",
            "name": "cn=ssp admins,cn=users,dc=ntnxlab,dc=local",
            "uuid": "45d495e1-b797-4a26-a45b-0ef589b42186"
          }
        ]
      }
    },
    "api_version": "3.1",
    "metadata": {
      "last_update_time": "2018-09-14T13:02:55Z",
      "kind": "directory_service",
      "uuid": "${_ldap_uuid}",
      "creation_time": "2018-09-14T13:02:55Z",
      "spec_version": 2,
      "owner_reference": {
        "kind": "user",
        "name": "admin",
        "uuid": "00000000-0000-0000-0000-000000000000"
      },
      "categories": {}
    }
  }
EOF
    )
    _ssp_connect=$(curl ${CURL_POST_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X PUT --data "${_http_body}" https://localhost:9440/api/nutanix/v3/directory_services/${_ldap_uuid})
    log "_ssp_connect=|${_ssp_connect}|"

}

###############################################################################################################################################################################
# Routine to enable Calm and proceed only if Calm is enabled
###############################################################################################################################################################################

function calm_enable() {
  local _http_body
  local _test
  local _sleep=30
  local CURL_HTTP_OPTS=' --max-time 25 --silent --header Content-Type:application/json --header Accept:application/json  --insecure '

  log "Enable Nutanix Calm..."
  # Need to check if the PE to PC registration has been done before we move forward to enable Calm. If we've done that, move on.
  _json_data="{\"perform_validation_only\":true}"
  _response=($(curl $CURL_HTTP_OPTS --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST -d "${_json_data}" https://localhost:9440/api/nutanix/v3/services/nucalm | jq '.validation_result_list[].has_passed'))
  while [ ${#_response[@]} -lt 4 ]; do
    _response=($(curl $CURL_HTTP_OPTS --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST -d "${_json_data}" https://localhost:9440/api/nutanix/v3/services/nucalm | jq '.validation_result_list[].has_passed'))
    sleep 10
  done


  _http_body='{"enable_nutanix_apps":true,"state":"ENABLE"}'
  _test=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST -d "${_http_body}" https://localhost:9440/api/nutanix/v3/services/nucalm)

  # Sometimes the enabling of Calm is stuck due to an internal error. Need to retry then.
  _error_calm=$(echo $_test | grep "\"state\": \"ERROR\"" | wc -l)
  while [ $_error_calm -gt 0 ]; do
      _test=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST -d "${_http_body}" https://localhost:9440/api/nutanix/v3/services/nucalm)
      _error_calm=$(echo $_test | grep "\"state\": \"ERROR\"" | wc -l)
  done

  log "_test=|${_test}|"

  # Check if Calm is enabled
  while true; do
    # Get the progress of the task
    _progress=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} https://localhost:9440/api/nutanix/v3/services/nucalm/status | jq '.service_enablement_status' 2>nul | tr -d \")
    if [[ ${_progress} == "ENABLED" ]]; then
      log "Calm has been Enabled..."
      break;
    else
      log "Still enabling Calm.....Sleeping ${_sleep} seconds"
      sleep ${_sleep}
    fi
  done
}





###############################################################################################################################################################################
# Routine to make changes to the PC UI; Colors, naming and the Welcome Banner
###############################################################################################################################################################################

function pc_ui() {
  # http://vcdx56.com/2017/08/change-nutanix-prism-ui-login-screen/
  local  _http_body
  local       _json
  local _pc_version
  local       _test
#{"type":"WELCOME_BANNER","username":"system_data","key":"welcome_banner_content","value":"${PRISM_ADMIN}:${PE_PASSWORD}@${CLUSTER_NAME}"} \
  _json=$(cat <<EOF
{"type":"custom_login_screen","key":"color_in","value":"#ADD100"} \
{"type":"custom_login_screen","key":"color_out","value":"#11A3D7"} \
{"type":"custom_login_screen","key":"product_title","value":"${CLUSTER_NAME},PC-${PC_VERSION}"} \
{"type":"custom_login_screen","key":"title","value":"Nutanix.HandsOnWorkshops.com,@${AUTH_FQDN}"} \
{"type":"WELCOME_BANNER","username":"system_data","key":"welcome_banner_status","value":true} \
{"type":"WELCOME_BANNER","username":"system_data","key":"welcome_banner_content","value":"${PRISM_ADMIN}:${PE_PASSWORD}"} \
{"type":"WELCOME_BANNER","username":"system_data","key":"disable_video","value":true} \
{"type":"UI_CONFIG","username":"system_data","key":"disable_2048","value":true} \
{"type":"UI_CONFIG","key":"autoLogoutGlobal","value":7200000} \
{"type":"UI_CONFIG","key":"autoLogoutOverride","value":0} \
{"type":"UI_CONFIG","key":"welcome_banner","value":"https://Nutanix.HandsOnWorkshops.com/workshops/6070f10d-3aa0-4c7e-b727-dc554cbc2ddf/start/"}
EOF
  )

  for _http_body in ${_json}; do
    _test=$(curl ${CURL_HTTP_OPTS} \
      --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST --data "${_http_body}" \
      https://localhost:9440/PrismGateway/services/rest/v1/application/system_data)
    log "_test=|${_test}|${_http_body}"
  done

  _http_body='{"type":"UI_CONFIG","key":"autoLogoutTime","value": 3600000}'
       _test=$(curl ${CURL_HTTP_OPTS} \
    --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST --data "${_http_body}" \
    https://localhost:9440/PrismGateway/services/rest/v1/application/user_data)
  log "autoLogoutTime _test=|${_test}|"

  # shellcheck disable=2206
  _pc_version=(${PC_VERSION//./ })

  if (( ${_pc_version[0]} >= 5 && ${_pc_version[1]} >= 10 && ${_test} != 500 )); then
    log "PC_VERSION ${PC_VERSION} >= 5.10, setting favorites..."

    _json=$(cat <<EOF
{"complete_query":"Karbon","route":"ebrowser/k8_cluster_entitys"} \
{"complete_query":"Images","route":"ebrowser/image_infos"} \
{"complete_query":"Projects","route":"ebrowser/projects"} \
{"complete_query":"Calm","route":"calm"}
EOF
    )

    for _http_body in ${_json}; do
      _test=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST --data "${_http_body}" \
        https://localhost:9440/api/nutanix/v3/search/favorites)
      log "favs _test=|${_test}|${_http_body}"
    done
  fi
}

#########################################################################################################################################
# Routine to Deploy VMs for POC Workshop
#########################################################################################################################################

function deploy_pocworkshop_vms() {
  local CURL_HTTP_OPTS=" --max-time 25 --silent --header Content-Type:application/json --header Accept:application/json  --insecure "

  #set -x

  log "Starting SE POC Guide Base VM Deployments"
  log "PE Cluster IP |${PE_HOST}|"
  log "PE Cluster IP |${PC_HOST}|"
  log "Cluster Name |${CLUSTER_NAME}|"

  ## Get Cluster UUID ##
  log "-------------------------------------"
  log "Get Cluster UUID"

  _cluster_uuid=$(curl ${CURL_HTTP_OPTS} -X POST 'https://localhost:9440/api/nutanix/v3/clusters/list' --user ${PRISM_ADMIN}:${PE_PASSWORD} --data '{}' | jq --arg CLUSTER "Unnamed" '.entities[]|select (.status.name!=$CLUSTER)| .metadata.uuid' | tr -d \")

  log "Cluster UUID |${_cluster_uuid}|"

  ## Get Primary Network UUID ##
  log "-------------------------------------"
  log "Get cluster network UUID"

  _nw_uuid=$(curl ${CURL_HTTP_OPTS} --request POST 'https://localhost:9440/api/nutanix/v3/subnets/list' --user ${PRISM_ADMIN}:${PE_PASSWORD} --data '{"kind":"subnet","filter": "name==Primary"}' | jq -r '.entities[] | .metadata.uuid' | tr -d \")

  log "NW UUID = ${_nw_uuid}"

  ## Get Windows Image UUID ##
  log "-------------------------------------"
  log "Get Windows Image UUID"

  _windows2016_uuid=$(curl ${CURL_HTTP_OPTS} -X POST 'https://localhost:9440/api/nutanix/v3/images/list' --user ${PRISM_ADMIN}:${PE_PASSWORD} --data '{"kind":"image","filter":"name==Windows2016.qcow2"}' | jq -r '.entities[] | .metadata.uuid' | tr -d \")

  log "Windows Image UUID |${_windows2016_uuid}|"

  ## Get CentOS7 Image UUID ##
  log "-------------------------------------"
  log "Get CentOS7 Image UUID"

  _centos7_uuid=$(curl ${CURL_HTTP_OPTS} -X POST 'https://localhost:9440/api/nutanix/v3/images/list' --user ${PRISM_ADMIN}:${PE_PASSWORD} --data '{"kind":"image","filter":"name==CentOS7.qcow2"}' | jq -r '.entities[] | .metadata.uuid' | tr -d \")

  log "CentOS7 Image UUID |${_centos7_uuid}|"

  ## VM Name Vars ##
  VMS=(\
     1 \
     2 \
     3 \
     4 \
     5 \
  )

  ## Creating the VMs ##
  log "-------------------------------------"
  Log "Creating the Windows and Linux VMs for use in the SE POC Guide"

  ## Creating the First WinServer VM ##

  VMName="WinServer"

  Log "Creating ${VMName}"

HTTP_JSON_BODY=$(cat <<EOF
{
    "api_version": "3.1.0",
    "metadata": {
        "categories": {},
        "kind": "vm"
    },
    "spec": {
        "cluster_reference": {
            "kind": "cluster",
            "uuid": "${_cluster_uuid}"
        },
        "name": "${VMName}",
        "resources": {
            "memory_size_mib": 4096,
            "num_sockets": 2,
            "num_vcpus_per_socket": 1,
            "power_state": "ON",
            "guest_customization": {
                "sysprep": {
                    "install_type": "PREPARED",
                    "unattend_xml": "PD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0iVVRGLTgiPz4NCjx1bmF0dGVuZCB4bWxucz0idXJuOnNjaGVtYXMtbWljcm9zb2Z0LWNvbTp1bmF0dGVuZCI+DQogICA8c2V0dGluZ3MgcGFzcz0ib29iZVN5c3RlbSI+DQogICAgICA8Y29tcG9uZW50IG5hbWU9Ik1pY3Jvc29mdC1XaW5kb3dzLVNoZWxsLVNldHVwIiB4bWxuczp3Y209Imh0dHA6Ly9zY2hlbWFzLm1pY3Jvc29mdC5jb20vV01JQ29uZmlnLzIwMDIvU3RhdGUiIHhtbG5zOnhzaT0iaHR0cDovL3d3dy53My5vcmcvMjAwMS9YTUxTY2hlbWEtaW5zdGFuY2UiIHByb2Nlc3NvckFyY2hpdGVjdHVyZT0iYW1kNjQiIHB1YmxpY0tleVRva2VuPSIzMWJmMzg1NmFkMzY0ZTM1IiBsYW5ndWFnZT0ibmV1dHJhbCIgdmVyc2lvblNjb3BlPSJub25TeFMiPg0KICAgICAgICAgPE9PQkU+DQogICAgICAgICAgICA8SGlkZUVVTEFQYWdlPnRydWU8L0hpZGVFVUxBUGFnZT4NCiAgICAgICAgICAgIDxIaWRlT0VNUmVnaXN0cmF0aW9uU2NyZWVuPnRydWU8L0hpZGVPRU1SZWdpc3RyYXRpb25TY3JlZW4+DQogICAgICAgICAgICA8SGlkZU9ubGluZUFjY291bnRTY3JlZW5zPnRydWU8L0hpZGVPbmxpbmVBY2NvdW50U2NyZWVucz4NCiAgICAgICAgICAgIDxIaWRlV2lyZWxlc3NTZXR1cEluT09CRT50cnVlPC9IaWRlV2lyZWxlc3NTZXR1cEluT09CRT4NCiAgICAgICAgICAgIDxOZXR3b3JrTG9jYXRpb24+V29yazwvTmV0d29ya0xvY2F0aW9uPg0KICAgICAgICAgICAgPFNraXBNYWNoaW5lT09CRT50cnVlPC9Ta2lwTWFjaGluZU9PQkU+DQogICAgICAgICA8L09PQkU+DQogICAgICAgICA8VXNlckFjY291bnRzPg0KICAgICAgICAgICAgPEFkbWluaXN0cmF0b3JQYXNzd29yZD4NCiAgICAgICAgICAgICAgIDxWYWx1ZT5udXRhbml4LzR1PC9WYWx1ZT4NCiAgICAgICAgICAgICAgIDxQbGFpblRleHQ+dHJ1ZTwvUGxhaW5UZXh0Pg0KICAgICAgICAgICAgPC9BZG1pbmlzdHJhdG9yUGFzc3dvcmQ+DQogICAgICAgICA8L1VzZXJBY2NvdW50cz4gIA0KICAgICAgPC9jb21wb25lbnQ+DQogICAgICA8Y29tcG9uZW50IG5hbWU9Ik1pY3Jvc29mdC1XaW5kb3dzLUludGVybmF0aW9uYWwtQ29yZSIgeG1sbnM6d2NtPSJodHRwOi8vc2NoZW1hcy5taWNyb3NvZnQuY29tL1dNSUNvbmZpZy8yMDAyL1N0YXRlIiB4bWxuczp4c2k9Imh0dHA6Ly93d3cudzMub3JnLzIwMDEvWE1MU2NoZW1hLWluc3RhbmNlIiBwcm9jZXNzb3JBcmNoaXRlY3R1cmU9ImFtZDY0IiBwdWJsaWNLZXlUb2tlbj0iMzFiZjM4NTZhZDM2NGUzNSIgbGFuZ3VhZ2U9Im5ldXRyYWwiIHZlcnNpb25TY29wZT0ibm9uU3hTIj4NCiAgICAgICAgIDxJbnB1dExvY2FsZT5lbi1VUzwvSW5wdXRMb2NhbGU+DQogICAgICAgICA8U3lzdGVtTG9jYWxlPmVuLVVTPC9TeXN0ZW1Mb2NhbGU+DQogICAgICAgICA8VUlMYW5ndWFnZUZhbGxiYWNrPmVuLXVzPC9VSUxhbmd1YWdlRmFsbGJhY2s+DQogICAgICAgICA8VUlMYW5ndWFnZT5lbi1VUzwvVUlMYW5ndWFnZT4NCiAgICAgICAgIDxVc2VyTG9jYWxlPmVuLVVTPC9Vc2VyTG9jYWxlPg0KICAgICAgPC9jb21wb25lbnQ+DQogICA8L3NldHRpbmdzPg0KICAgPHNldHRpbmdzIHBhc3M9InNwZWNpYWxpemUiPg0KICAgICAgPGNvbXBvbmVudCBuYW1lPSJNaWNyb3NvZnQtV2luZG93cy1TaGVsbC1TZXR1cCIgeG1sbnM6d2NtPSJodHRwOi8vc2NoZW1hcy5taWNyb3NvZnQuY29tL1dNSUNvbmZpZy8yMDAyL1N0YXRlIiB4bWxuczp4c2k9Imh0dHA6Ly93d3cudzMub3JnLzIwMDEvWE1MU2NoZW1hLWluc3RhbmNlIiBwcm9jZXNzb3JBcmNoaXRlY3R1cmU9ImFtZDY0IiBwdWJsaWNLZXlUb2tlbj0iMzFiZjM4NTZhZDM2NGUzNSIgbGFuZ3VhZ2U9Im5ldXRyYWwiIHZlcnNpb25TY29wZT0ibm9uU3hTIj4NCiAgICAgICAgIDxDb21wdXRlck5hbWU+KjwvQ29tcHV0ZXJOYW1lPg0KICAgICAgICAgPFJlZ2lzdGVyZWRPcmdhbml6YXRpb24+TnV0YW5peDwvUmVnaXN0ZXJlZE9yZ2FuaXphdGlvbj4NCiAgICAgICAgIDxSZWdpc3RlcmVkT3duZXI+QWNyb3BvbGlzPC9SZWdpc3RlcmVkT3duZXI+DQogICAgICAgICA8VGltZVpvbmU+VVRDPC9UaW1lWm9uZT4NCiAgICAgIDwvY29tcG9uZW50Pg0KICAgICAgPGNvbXBvbmVudCBuYW1lPSJNaWNyb3NvZnQtV2luZG93cy1VbmF0dGVuZGVkSm9pbiIgcHJvY2Vzc29yQXJjaGl0ZWN0dXJlPSJhbWQ2NCIgcHVibGljS2V5VG9rZW49IjMxYmYzODU2YWQzNjRlMzUiIGxhbmd1YWdlPSJuZXV0cmFsIiB2ZXJzaW9uU2NvcGU9Im5vblN4UyIgeG1sbnM6d2NtPSJodHRwOi8vc2NoZW1hcy5taWNyb3NvZnQuY29tL1dNSUNvbmZpZy8yMDAyL1N0YXRlIiB4bWxuczp4c2k9Imh0dHA6Ly93d3cudzMub3JnLzIwMDEvWE1MU2NoZW1hLWluc3RhbmNlIj4NCiAgICAgICAgICAgIDxJZGVudGlmaWNhdGlvbj4NCiAgICAgICAgICAgICAgICA8VW5zZWN1cmVKb2luPmZhbHNlPC9VbnNlY3VyZUpvaW4+DQogICAgICAgICAgICAgICAgPENyZWRlbnRpYWxzPg0KICAgICAgICAgICAgICAgICAgICA8RG9tYWluPm50bnhsYWIubG9jYWw8L0RvbWFpbj4NCiAgICAgICAgICAgICAgICAgICAgPFBhc3N3b3JkPm51dGFuaXgvNHU8L1Bhc3N3b3JkPg0KICAgICAgICAgICAgICAgICAgICA8VXNlcm5hbWU+YWRtaW5pc3RyYXRvcjwvVXNlcm5hbWU+DQogICAgICAgICAgICAgICAgPC9DcmVkZW50aWFscz4NCiAgICAgICAgICAgICAgICA8Sm9pbkRvbWFpbj5udG54bGFiLmxvY2FsPC9Kb2luRG9tYWluPg0KICAgICAgICAgICAgPC9JZGVudGlmaWNhdGlvbj4NCiAgICAgIDwvY29tcG9uZW50Pg0KICAgICAgPGNvbXBvbmVudCBuYW1lPSJNaWNyb3NvZnQtV2luZG93cy1UZXJtaW5hbFNlcnZpY2VzLUxvY2FsU2Vzc2lvbk1hbmFnZXIiIHhtbG5zPSIiIHB1YmxpY0tleVRva2VuPSIzMWJmMzg1NmFkMzY0ZTM1IiBsYW5ndWFnZT0ibmV1dHJhbCIgdmVyc2lvblNjb3BlPSJub25TeFMiIHByb2Nlc3NvckFyY2hpdGVjdHVyZT0iYW1kNjQiPg0KICAgICAgICAgPGZEZW55VFNDb25uZWN0aW9ucz5mYWxzZTwvZkRlbnlUU0Nvbm5lY3Rpb25zPg0KICAgICAgPC9jb21wb25lbnQ+DQogICAgICA8Y29tcG9uZW50IG5hbWU9Ik1pY3Jvc29mdC1XaW5kb3dzLVRlcm1pbmFsU2VydmljZXMtUkRQLVdpblN0YXRpb25FeHRlbnNpb25zIiB4bWxucz0iIiBwdWJsaWNLZXlUb2tlbj0iMzFiZjM4NTZhZDM2NGUzNSIgbGFuZ3VhZ2U9Im5ldXRyYWwiIHZlcnNpb25TY29wZT0ibm9uU3hTIiBwcm9jZXNzb3JBcmNoaXRlY3R1cmU9ImFtZDY0Ij4NCiAgICAgICAgIDxVc2VyQXV0aGVudGljYXRpb24+MDwvVXNlckF1dGhlbnRpY2F0aW9uPg0KICAgICAgPC9jb21wb25lbnQ+DQogICAgICA8Y29tcG9uZW50IG5hbWU9Ik5ldHdvcmtpbmctTVBTU1ZDLVN2YyIgcHJvY2Vzc29yQXJjaGl0ZWN0dXJlPSJhbWQ2NCIgcHVibGljS2V5VG9rZW49IjMxYmYzODU2YWQzNjRlMzUiIGxhbmd1YWdlPSJuZXV0cmFsIiB2ZXJzaW9uU2NvcGU9Im5vblN4UyIgeG1sbnM6d2NtPSJodHRwOi8vc2NoZW1hcy5taWNyb3NvZnQuY29tL1dNSUNvbmZpZy8yMDAyL1N0YXRlIiB4bWxuczp4c2k9Imh0dHA6Ly93d3cudzMub3JnLzIwMDEvWE1MU2NoZW1hLWluc3RhbmNlIj4NCiAgICAgICAgICAgIDxEb21haW5Qcm9maWxlX0VuYWJsZUZpcmV3YWxsPmZhbHNlPC9Eb21haW5Qcm9maWxlX0VuYWJsZUZpcmV3YWxsPg0KICAgICAgICAgICAgPFByaXZhdGVQcm9maWxlX0VuYWJsZUZpcmV3YWxsPmZhbHNlPC9Qcml2YXRlUHJvZmlsZV9FbmFibGVGaXJld2FsbD4NCiAgICAgICAgICAgIDxQdWJsaWNQcm9maWxlX0VuYWJsZUZpcmV3YWxsPmZhbHNlPC9QdWJsaWNQcm9maWxlX0VuYWJsZUZpcmV3YWxsPg0KICAgICAgPC9jb21wb25lbnQ+DQogICA8L3NldHRpbmdzPg0KPC91bmF0dGVuZD4="
                }
            },
            "disk_list": [
                {
                    "device_properties": {
                        "device_type": "DISK",
                        "disk_address": {
                            "device_index": 0,
                            "adapter_type": "SCSI"
                        }
                    },
                    "data_source_reference": {
                        "kind": "image",
                        "uuid": "${_windows2016_uuid}"
                    }
                },
                {
                    "device_properties": {
                        "device_type": "CDROM"
                    }
                }
            ],
            "nic_list": [
                {
                    "nic_type": "NORMAL_NIC",
                    "is_connected": true,
                    "ip_endpoint_list": [
                        {
                            "ip_type": "DHCP"
                        }
                    ],
                    "subnet_reference": {
                        "kind": "subnet",
                        "name": "Primary",
                        "uuid": "${_nw_uuid}"
                    }
                }
            ]
        }
    }
}
EOF
)

  _task_id=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST --data "${HTTP_JSON_BODY}" 'https://localhost:9440/api/nutanix/v3/vms' | jq -r '.status.execution_context.task_uuid' | tr -d \")

  if [ -z "$_task_id" ]; then
       log "${VMName} Deployment has encountered an error..."
  else
       log "${VMName} Deployment started.."
       set _loops=0 # Reset the loop counter so we restart the amount of loops we need to run
       # Run the progess checker
       loop
  fi

  log "${VMName} Deployment Completed"

  ## Creating WinServer VMs 1-5 ##

  for _vm in "${VMS[@]}" ; do

  VMName="WinServer-${_vm}"

  log "Creating ${VMName} Now"

HTTP_JSON_BODY=$(cat <<EOF
{
    "api_version": "3.1.0",
    "metadata": {
        "categories": {},
        "kind": "vm"
    },
    "spec": {
        "cluster_reference": {
            "kind": "cluster",
            "uuid": "${_cluster_uuid}"
        },
        "name": "${VMName}",
        "resources": {
            "memory_size_mib": 4096,
            "num_sockets": 2,
            "num_vcpus_per_socket": 1,
            "power_state": "ON",
            "guest_customization": {
                "sysprep": {
                    "install_type": "PREPARED",
                    "unattend_xml": "PD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0iVVRGLTgiPz4NCjx1bmF0dGVuZCB4bWxucz0idXJuOnNjaGVtYXMtbWljcm9zb2Z0LWNvbTp1bmF0dGVuZCI+DQogICA8c2V0dGluZ3MgcGFzcz0ib29iZVN5c3RlbSI+DQogICAgICA8Y29tcG9uZW50IG5hbWU9Ik1pY3Jvc29mdC1XaW5kb3dzLVNoZWxsLVNldHVwIiB4bWxuczp3Y209Imh0dHA6Ly9zY2hlbWFzLm1pY3Jvc29mdC5jb20vV01JQ29uZmlnLzIwMDIvU3RhdGUiIHhtbG5zOnhzaT0iaHR0cDovL3d3dy53My5vcmcvMjAwMS9YTUxTY2hlbWEtaW5zdGFuY2UiIHByb2Nlc3NvckFyY2hpdGVjdHVyZT0iYW1kNjQiIHB1YmxpY0tleVRva2VuPSIzMWJmMzg1NmFkMzY0ZTM1IiBsYW5ndWFnZT0ibmV1dHJhbCIgdmVyc2lvblNjb3BlPSJub25TeFMiPg0KICAgICAgICAgPE9PQkU+DQogICAgICAgICAgICA8SGlkZUVVTEFQYWdlPnRydWU8L0hpZGVFVUxBUGFnZT4NCiAgICAgICAgICAgIDxIaWRlT0VNUmVnaXN0cmF0aW9uU2NyZWVuPnRydWU8L0hpZGVPRU1SZWdpc3RyYXRpb25TY3JlZW4+DQogICAgICAgICAgICA8SGlkZU9ubGluZUFjY291bnRTY3JlZW5zPnRydWU8L0hpZGVPbmxpbmVBY2NvdW50U2NyZWVucz4NCiAgICAgICAgICAgIDxIaWRlV2lyZWxlc3NTZXR1cEluT09CRT50cnVlPC9IaWRlV2lyZWxlc3NTZXR1cEluT09CRT4NCiAgICAgICAgICAgIDxOZXR3b3JrTG9jYXRpb24+V29yazwvTmV0d29ya0xvY2F0aW9uPg0KICAgICAgICAgICAgPFNraXBNYWNoaW5lT09CRT50cnVlPC9Ta2lwTWFjaGluZU9PQkU+DQogICAgICAgICA8L09PQkU+DQogICAgICAgICA8VXNlckFjY291bnRzPg0KICAgICAgICAgICAgPEFkbWluaXN0cmF0b3JQYXNzd29yZD4NCiAgICAgICAgICAgICAgIDxWYWx1ZT5udXRhbml4LzR1PC9WYWx1ZT4NCiAgICAgICAgICAgICAgIDxQbGFpblRleHQ+dHJ1ZTwvUGxhaW5UZXh0Pg0KICAgICAgICAgICAgPC9BZG1pbmlzdHJhdG9yUGFzc3dvcmQ+DQogICAgICAgICA8L1VzZXJBY2NvdW50cz4gIA0KICAgICAgPC9jb21wb25lbnQ+DQogICAgICA8Y29tcG9uZW50IG5hbWU9Ik1pY3Jvc29mdC1XaW5kb3dzLUludGVybmF0aW9uYWwtQ29yZSIgeG1sbnM6d2NtPSJodHRwOi8vc2NoZW1hcy5taWNyb3NvZnQuY29tL1dNSUNvbmZpZy8yMDAyL1N0YXRlIiB4bWxuczp4c2k9Imh0dHA6Ly93d3cudzMub3JnLzIwMDEvWE1MU2NoZW1hLWluc3RhbmNlIiBwcm9jZXNzb3JBcmNoaXRlY3R1cmU9ImFtZDY0IiBwdWJsaWNLZXlUb2tlbj0iMzFiZjM4NTZhZDM2NGUzNSIgbGFuZ3VhZ2U9Im5ldXRyYWwiIHZlcnNpb25TY29wZT0ibm9uU3hTIj4NCiAgICAgICAgIDxJbnB1dExvY2FsZT5lbi1VUzwvSW5wdXRMb2NhbGU+DQogICAgICAgICA8U3lzdGVtTG9jYWxlPmVuLVVTPC9TeXN0ZW1Mb2NhbGU+DQogICAgICAgICA8VUlMYW5ndWFnZUZhbGxiYWNrPmVuLXVzPC9VSUxhbmd1YWdlRmFsbGJhY2s+DQogICAgICAgICA8VUlMYW5ndWFnZT5lbi1VUzwvVUlMYW5ndWFnZT4NCiAgICAgICAgIDxVc2VyTG9jYWxlPmVuLVVTPC9Vc2VyTG9jYWxlPg0KICAgICAgPC9jb21wb25lbnQ+DQogICA8L3NldHRpbmdzPg0KICAgPHNldHRpbmdzIHBhc3M9InNwZWNpYWxpemUiPg0KICAgICAgPGNvbXBvbmVudCBuYW1lPSJNaWNyb3NvZnQtV2luZG93cy1TaGVsbC1TZXR1cCIgeG1sbnM6d2NtPSJodHRwOi8vc2NoZW1hcy5taWNyb3NvZnQuY29tL1dNSUNvbmZpZy8yMDAyL1N0YXRlIiB4bWxuczp4c2k9Imh0dHA6Ly93d3cudzMub3JnLzIwMDEvWE1MU2NoZW1hLWluc3RhbmNlIiBwcm9jZXNzb3JBcmNoaXRlY3R1cmU9ImFtZDY0IiBwdWJsaWNLZXlUb2tlbj0iMzFiZjM4NTZhZDM2NGUzNSIgbGFuZ3VhZ2U9Im5ldXRyYWwiIHZlcnNpb25TY29wZT0ibm9uU3hTIj4NCiAgICAgICAgIDxDb21wdXRlck5hbWU+KjwvQ29tcHV0ZXJOYW1lPg0KICAgICAgICAgPFJlZ2lzdGVyZWRPcmdhbml6YXRpb24+TnV0YW5peDwvUmVnaXN0ZXJlZE9yZ2FuaXphdGlvbj4NCiAgICAgICAgIDxSZWdpc3RlcmVkT3duZXI+QWNyb3BvbGlzPC9SZWdpc3RlcmVkT3duZXI+DQogICAgICAgICA8VGltZVpvbmU+VVRDPC9UaW1lWm9uZT4NCiAgICAgIDwvY29tcG9uZW50Pg0KICAgICAgPGNvbXBvbmVudCBuYW1lPSJNaWNyb3NvZnQtV2luZG93cy1VbmF0dGVuZGVkSm9pbiIgcHJvY2Vzc29yQXJjaGl0ZWN0dXJlPSJhbWQ2NCIgcHVibGljS2V5VG9rZW49IjMxYmYzODU2YWQzNjRlMzUiIGxhbmd1YWdlPSJuZXV0cmFsIiB2ZXJzaW9uU2NvcGU9Im5vblN4UyIgeG1sbnM6d2NtPSJodHRwOi8vc2NoZW1hcy5taWNyb3NvZnQuY29tL1dNSUNvbmZpZy8yMDAyL1N0YXRlIiB4bWxuczp4c2k9Imh0dHA6Ly93d3cudzMub3JnLzIwMDEvWE1MU2NoZW1hLWluc3RhbmNlIj4NCiAgICAgICAgICAgIDxJZGVudGlmaWNhdGlvbj4NCiAgICAgICAgICAgICAgICA8VW5zZWN1cmVKb2luPmZhbHNlPC9VbnNlY3VyZUpvaW4+DQogICAgICAgICAgICAgICAgPENyZWRlbnRpYWxzPg0KICAgICAgICAgICAgICAgICAgICA8RG9tYWluPm50bnhsYWIubG9jYWw8L0RvbWFpbj4NCiAgICAgICAgICAgICAgICAgICAgPFBhc3N3b3JkPm51dGFuaXgvNHU8L1Bhc3N3b3JkPg0KICAgICAgICAgICAgICAgICAgICA8VXNlcm5hbWU+YWRtaW5pc3RyYXRvcjwvVXNlcm5hbWU+DQogICAgICAgICAgICAgICAgPC9DcmVkZW50aWFscz4NCiAgICAgICAgICAgICAgICA8Sm9pbkRvbWFpbj5udG54bGFiLmxvY2FsPC9Kb2luRG9tYWluPg0KICAgICAgICAgICAgPC9JZGVudGlmaWNhdGlvbj4NCiAgICAgIDwvY29tcG9uZW50Pg0KICAgICAgPGNvbXBvbmVudCBuYW1lPSJNaWNyb3NvZnQtV2luZG93cy1UZXJtaW5hbFNlcnZpY2VzLUxvY2FsU2Vzc2lvbk1hbmFnZXIiIHhtbG5zPSIiIHB1YmxpY0tleVRva2VuPSIzMWJmMzg1NmFkMzY0ZTM1IiBsYW5ndWFnZT0ibmV1dHJhbCIgdmVyc2lvblNjb3BlPSJub25TeFMiIHByb2Nlc3NvckFyY2hpdGVjdHVyZT0iYW1kNjQiPg0KICAgICAgICAgPGZEZW55VFNDb25uZWN0aW9ucz5mYWxzZTwvZkRlbnlUU0Nvbm5lY3Rpb25zPg0KICAgICAgPC9jb21wb25lbnQ+DQogICAgICA8Y29tcG9uZW50IG5hbWU9Ik1pY3Jvc29mdC1XaW5kb3dzLVRlcm1pbmFsU2VydmljZXMtUkRQLVdpblN0YXRpb25FeHRlbnNpb25zIiB4bWxucz0iIiBwdWJsaWNLZXlUb2tlbj0iMzFiZjM4NTZhZDM2NGUzNSIgbGFuZ3VhZ2U9Im5ldXRyYWwiIHZlcnNpb25TY29wZT0ibm9uU3hTIiBwcm9jZXNzb3JBcmNoaXRlY3R1cmU9ImFtZDY0Ij4NCiAgICAgICAgIDxVc2VyQXV0aGVudGljYXRpb24+MDwvVXNlckF1dGhlbnRpY2F0aW9uPg0KICAgICAgPC9jb21wb25lbnQ+DQogICAgICA8Y29tcG9uZW50IG5hbWU9Ik5ldHdvcmtpbmctTVBTU1ZDLVN2YyIgcHJvY2Vzc29yQXJjaGl0ZWN0dXJlPSJhbWQ2NCIgcHVibGljS2V5VG9rZW49IjMxYmYzODU2YWQzNjRlMzUiIGxhbmd1YWdlPSJuZXV0cmFsIiB2ZXJzaW9uU2NvcGU9Im5vblN4UyIgeG1sbnM6d2NtPSJodHRwOi8vc2NoZW1hcy5taWNyb3NvZnQuY29tL1dNSUNvbmZpZy8yMDAyL1N0YXRlIiB4bWxuczp4c2k9Imh0dHA6Ly93d3cudzMub3JnLzIwMDEvWE1MU2NoZW1hLWluc3RhbmNlIj4NCiAgICAgICAgICAgIDxEb21haW5Qcm9maWxlX0VuYWJsZUZpcmV3YWxsPmZhbHNlPC9Eb21haW5Qcm9maWxlX0VuYWJsZUZpcmV3YWxsPg0KICAgICAgICAgICAgPFByaXZhdGVQcm9maWxlX0VuYWJsZUZpcmV3YWxsPmZhbHNlPC9Qcml2YXRlUHJvZmlsZV9FbmFibGVGaXJld2FsbD4NCiAgICAgICAgICAgIDxQdWJsaWNQcm9maWxlX0VuYWJsZUZpcmV3YWxsPmZhbHNlPC9QdWJsaWNQcm9maWxlX0VuYWJsZUZpcmV3YWxsPg0KICAgICAgPC9jb21wb25lbnQ+DQogICA8L3NldHRpbmdzPg0KPC91bmF0dGVuZD4="
                }
            },
            "disk_list": [
                {
                    "device_properties": {
                        "device_type": "DISK",
                        "disk_address": {
                            "device_index": 0,
                            "adapter_type": "SCSI"
                        }
                    },
                    "data_source_reference": {
                        "kind": "image",
                        "uuid": "${_windows2016_uuid}"
                    }
                },
                {
                    "device_properties": {
                        "device_type": "CDROM"
                    }
                }
            ],
            "nic_list": [
                {
                    "nic_type": "NORMAL_NIC",
                    "is_connected": true,
                    "ip_endpoint_list": [
                        {
                            "ip_type": "DHCP"
                        }
                    ],
                    "subnet_reference": {
                        "kind": "subnet",
                        "name": "Primary",
                        "uuid": "${_nw_uuid}"
                    }
                }
            ]
        }
    }
}
EOF
)

  # Run the upgrade to have the latest versions
  _task_id=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST --data "${HTTP_JSON_BODY}" 'https://localhost:9440/api/nutanix/v3/vms' | jq -r '.status.execution_context.task_uuid' | tr -d \")

  if [ -z "$_task_id" ]; then
       log "${VMName} Deployment has encountered an error..."
  else
       log "${VMName} Deployment started.."
       set _loops=0 # Reset the loop counter so we restart the amount of loops we need to run
       # Run the progess checker
       loop
  fi

  log "${VMName} Deployment Completed"

  done

  ## Creating the CentOS VM ##

  VMName="CentOS"

  Log "Creating ${VMName}"

HTTP_JSON_BODY=$(cat <<EOF
{
    "api_version": "3.1.0",
    "metadata": {
        "categories": {},
        "kind": "vm"
    },
    "spec": {
        "cluster_reference": {
            "kind": "cluster",
            "uuid": "${_cluster_uuid}"
        },
        "name": "${VMName}",
        "resources": {
            "memory_size_mib": 4096,
            "num_sockets": 2,
            "num_vcpus_per_socket": 1,
            "power_state": "ON",
            "disk_list": [
                {
                    "device_properties": {
                        "device_type": "DISK",
                        "disk_address": {
                            "device_index": 0,
                            "adapter_type": "SCSI"
                        }
                    },
                    "data_source_reference": {
                        "kind": "image",
                        "uuid": "${_centos7_uuid}"
                    }
                },
                {
                    "device_properties": {
                        "device_type": "CDROM"
                    }
                }
            ],
            "nic_list": [
                {
                    "nic_type": "NORMAL_NIC",
                    "is_connected": true,
                    "ip_endpoint_list": [
                        {
                            "ip_type": "DHCP"
                        }
                    ],
                    "subnet_reference": {
                        "kind": "subnet",
                        "name": "Primary",
                        "uuid": "${_nw_uuid}"
                    }
                }
            ]
        }
    }
}
EOF
)

  _task_id=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST --data "${HTTP_JSON_BODY}" 'https://localhost:9440/api/nutanix/v3/vms' | jq -r '.status.execution_context.task_uuid' | tr -d \")

  if [ -z "$_task_id" ]; then
       log "${VMName} Deployment has encountered an error..."
  else
       log "${VMName} Deployment started.."
       set _loops=0 # Reset the loop counter so we restart the amount of loops we need to run
       # Run the progess checker
       loop
  fi

  log "${VMName} Deployment Completed"




#set +x

}

#########################################################################################################################################
# Routine to configure Era
#########################################################################################################################################

function configure_era() {
  local CURL_HTTP_OPTS=" --max-time 25 --silent --header Content-Type:application/json --header Accept:application/json  --insecure "

#set -x

log "Starting Era Config"

log "PE Cluster IP |${PE_HOST}|"
log "EraServer IP |${ERA_HOST}|"

##  Create the EraManaged network inside Era ##
log "Reset Default Era Password"

  _reset_passwd=$(curl ${CURL_HTTP_OPTS} -u ${ERA_USER}:${ERA_Default_PASSWORD} -X POST "https://${ERA_HOST}/era/v0.9/auth/update" --data '{ "password": "'${ERA_PASSWORD}'"}' | jq -r '.status' | tr -d \")

log "Password Reset |${_reset_passwd}|"

##  Accept EULA ##
log "Accept Era EULA"

  _accept_eula=$(curl ${CURL_HTTP_OPTS} -u ${ERA_USER}:${ERA_PASSWORD} -X POST "https://${ERA_HOST}/era/v0.9/auth/validate" --data '{ "eulaAccepted": true }' | jq -r '.status' | tr -d \")

log "Accept EULA |${_accept_eula}|"

##  Register Cluster  ##
log "Register ${CLUSTER_NAME} with Era"

HTTP_JSON_BODY=$(cat <<EOF
{
    "name": "EraCluster",
    "description": "Era Bootcamp Cluster",
    "ip": "${PE_HOST}",
    "username": "${PRISM_ADMIN}",
    "password": "${PE_PASSWORD}",
    "status": "UP",
    "version": "v2",
    "cloudType": "NTNX",
    "properties": [
        {
            "name": "ERA_STORAGE_CONTAINER",
            "value": "${STORAGE_ERA}"
        }
    ]
}
EOF
)

  _era_cluster_id=$(curl ${CURL_HTTP_OPTS} -u ${ERA_USER}:${ERA_PASSWORD} -X POST "https://${ERA_HOST}/era/v0.9/clusters" --data "${HTTP_JSON_BODY}" | jq -r '.id' | tr -d \")

log "Era Cluster ID: |${_era_cluster_id}|"

##  Update EraCluster ##
log "Updating Era Cluster ID: |${_era_cluster_id}|"

ClusterJSON='{"ip_address": "'${PE_HOST}'","port": "9440","protocol": "https","default_storage_container": "'${STORAGE_ERA}'","creds_bag": {"username": "'${PRISM_ADMIN}'","password": "'${PE_PASSWORD}'"}}'

echo $ClusterJSON > cluster.json

  _task_id=$(curl -k -H 'Content-Type: multipart/form-data' -u ${ERA_USER}:${ERA_PASSWORD} -X POST "https://${ERA_HOST}/era/v0.9/clusters/${_era_cluster_id}/json" -F file="@"cluster.json)

##  Add the Secondary Network inside Era ##
log "Create ${NW2_NAME} DHCP/IPAM Network"

  _dhcp_network_id=$(curl ${CURL_HTTP_OPTS} -u ${ERA_USER}:${ERA_PASSWORD} -X POST "https://${ERA_HOST}/era/v0.9/resources/networks" --data '{"name": "'${NW2_NAME}'","type": "DHCP"}' | jq -r '.id' | tr -d \")

log "Created ${NW2_NAME} Network with Network ID |${_dhcp_network_id}|"

##  Create the EraManaged network inside Era ##
log "Create ${NW3_NAME} Static Network"

HTTP_JSON_BODY=$(cat <<EOF
{
    "name": "${NW3_NAME}",
    "type": "Static",
    "ipPools": [
        {
            "startIP": "${NW3_START}",
            "endIP": "${NW3_END}"
        }
    ],
    "properties": [
        {
            "name": "VLAN_GATEWAY",
            "value": "${NW2_GATEWAY}"
        },
        {
            "name": "VLAN_PRIMARY_DNS",
            "value": "${AUTH_HOST}"
        },
        {
            "name": "VLAN_SUBNET_MASK",
            "value": "${NW3_NETMASK}"
        },
        {
    		"name": "VLAN_DNS_DOMAIN",
    		"value": "ntnxlab.local"
    	  }
    ]
}
EOF
)

  _static_network_id=$(curl ${CURL_HTTP_OPTS} -u ${ERA_USER}:${ERA_PASSWORD} -X POST "https://${ERA_HOST}/era/v0.9/resources/networks" --data "${HTTP_JSON_BODY}" | jq -r '.id' | tr -d \")

log "Created ${NW3_NAME} Network with Network ID |${_static_network_id}|"

##  Create the Primary-MSSQL-NETWORK Network Profile inside Era ##
log "Create the Primary-MSSQL-NETWORK Network Profile"

HTTP_JSON_BODY=$(cat <<EOF
{
  "engineType": "sqlserver_database",
  "type": "Network",
  "topology": "ALL",
  "dbVersion": "ALL",
  "systemProfile": false,
  "properties": [
    {
      "name": "VLAN_NAME",
      "value": "${ERA_NETWORK}",
      "description": "Name of the vLAN"
    }
  ],
  "name": "Primary-MSSQL-NETWORK"
}
EOF
)

  _primary_network_profile_id=$(curl ${CURL_HTTP_OPTS} -u ${ERA_USER}:${ERA_PASSWORD} -X POST "https://${ERA_HOST}/era/v0.9/profiles" --data "${HTTP_JSON_BODY}" | jq -r '.id' | tr -d \")

log "Created Primary-MSSQL-NETWORK Network Profile with ID |${_primary_network_profile_id}|"

##  Create the Primary_ORACLE_NETWORKNetwork Profile inside Era ##
log "Create the Primary_PGSQL_NETWORK Network Profile"

HTTP_JSON_BODY=$(cat <<EOF
{
  "engineType": "postgres_database",
  "type": "Network",
  "topology": "ALL",
  "dbVersion": "ALL",
  "systemProfile": false,
  "properties": [
    {
      "name": "VLAN_NAME",
      "value": "${ERA_NETWORK}",
      "description": "Name of the vLAN"
    }
  ],
  "name": "Primary-PGSQL-NETWORK"
}
EOF
)

  _postgres_network_profile_id=$(curl ${CURL_HTTP_OPTS} -u ${ERA_USER}:${ERA_PASSWORD} -X POST "https://${ERA_HOST}/era/v0.9/profiles" --data "${HTTP_JSON_BODY}" | jq -r '.id' | tr -d \")

log "Created Primary_PGSQL_NETWORK Network Profile with ID |${_postgres_network_profile_id}|"

##  Create the Primary_ORACLE_NETWORKNetwork Profile inside Era ##
log "Create the Primary_ORACLE_NETWORK Network Profile"

HTTP_JSON_BODY=$(cat <<EOF
{
  "engineType": "oracle_database",
  "type": "Network",
  "topology": "single",
  "dbVersion": "ALL",
  "systemProfile": false,
  "properties": [
    {
      "name": "VLAN_NAME",
      "value": "${ERA_NETWORK}",
      "description": "Name of the vLAN"
    }
  ],
  "name": "Primary_ORACLE_NETWORK"
}
EOF
)

  _oracle_network_profile_id=$(curl ${CURL_HTTP_OPTS} -u ${ERA_USER}:${ERA_PASSWORD} -X POST "https://${ERA_HOST}/era/v0.9/profiles" --data "${HTTP_JSON_BODY}" | jq -r '.id' | tr -d \")

log "Created Primary_ORACLE_NETWORK Network Profile with ID |${_oracle_network_profile_id}|"

##  Create the ERAMANAGED_MSSQL_NETWORK Network Profile inside Era ##
log "Create the ERAMANAGED_MSSQL_NETWORK Network Profile"

HTTP_JSON_BODY=$(cat <<EOF
{
  "engineType": "sqlserver_database",
  "type": "Network",
  "topology": "ALL",
  "dbVersion": "ALL",
  "systemProfile": false,
  "properties": [
    {
      "name": "VLAN_NAME",
      "value": "${NW3_NAME}",
      "description": "Name of the vLAN"
    }
  ],
  "name": "ERAMANAGED_MSSQL_NETWORK"
}
EOF
)

  _eramanagaed_network_profile_id=$(curl ${CURL_HTTP_OPTS} -u ${ERA_USER}:${ERA_PASSWORD} -X POST "https://${ERA_HOST}/era/v0.9/profiles" --data "${HTTP_JSON_BODY}" | jq -r '.id' | tr -d \")

log "Created ERAMANAGED_MSSQL_NETWORK Network Profile with ID |${_eramanagaed_network_profile_id}|"

##  Create the CUSTOM_EXTRA_SMALL Compute Profile inside Era ##
log "Create the CUSTOM_EXTRA_SMALL Compute Profile"

HTTP_JSON_BODY=$(cat <<EOF
{
  "type": "Compute",
  "topology": "ALL",
  "dbVersion": "ALL",
  "systemProfile": false,
  "properties": [
    {
      "name": "CPUS",
      "value": "1",
      "description": "Number of CPUs in the VM"
    },
    {
      "name": "CORE_PER_CPU",
      "value": "2",
      "description": "Number of cores per CPU in the VM"
    },
    {
      "name": "MEMORY_SIZE",
      "value": 4,
      "description": "Total memory (GiB) for the VM"
    }
  ],
  "name": "CUSTOM_EXTRA_SMALL"
}
EOF
)

  _xs_compute_profile_id=$(curl ${CURL_HTTP_OPTS} -u ${ERA_USER}:${ERA_PASSWORD} -X POST "https://${ERA_HOST}/era/v0.9/profiles" --data "${HTTP_JSON_BODY}" | jq -r '.id' | tr -d \")

log "Created CUSTOM_EXTRA_SMALL Compute Profile with ID |${_xs_compute_profile_id}|"

##  Create the ORACLE_SMALL Compute Profile inside Era ##
log "Create the ORACLE_SMALL Compute Profile"

HTTP_JSON_BODY=$(cat <<EOF
{
  "type": "Compute",
  "topology": "ALL",
  "dbVersion": "ALL",
  "systemProfile": false,
  "properties": [
    {
      "name": "CPUS",
      "value": "1",
      "description": "Number of CPUs in the VM"
    },
    {
      "name": "CORE_PER_CPU",
      "value": 4,
      "description": "Number of cores per CPU in the VM"
    },
    {
      "name": "MEMORY_SIZE",
      "value": 8,
      "description": "Total memory (GiB) for the VM"
    }
  ],
  "name": "ORACLE_SMALL"
}
EOF
)

  _oracle_small_compute_profile_id=$(curl ${CURL_HTTP_OPTS} -u ${ERA_USER}:${ERA_PASSWORD} -X POST "https://${ERA_HOST}/era/v0.9/profiles" --data "${HTTP_JSON_BODY}" | jq -r '.id' | tr -d \")

log "Created ORACLE_SMALL Compute Profile with ID |${_oracle_small_compute_profile_id}|"

##  Create the NTNXLAB Domain Profile inside Era ##
log "Create the NTNXLAB Domain Profile"

HTTP_JSON_BODY=$(cat <<EOF
{
  "engineType": "sqlserver_database",
  "type": "WindowsDomain",
  "topology": "ALL",
  "dbVersion": "ALL",
  "systemProfile": false,
  "properties": [
    {
      "name": "DOMAIN_NAME",
      "value": "ntnxlab.local",
      "secure": false,
      "description": "Name of the Windows domain"
    },
    {
      "name": "DOMAIN_USER_NAME",
      "value": "Administrator@ntnxlab.local",
      "secure": false,
      "description": "Username with permission to join computer to domain"
    },
    {
      "name": "DOMAIN_USER_PASSWORD",
      "value": "nutanix/4u",
      "secure": false,
      "description": "Password for the username with permission to join computer to domain"
    },
    {
      "name": "DB_SERVER_OU_PATH",
      "value": "",
      "secure": false,
      "description": "Custom OU path for database servers"
    },
    {
      "name": "CLUSTER_OU_PATH",
      "value": "",
      "secure": false,
      "description": "Custom OU path for server clusters"
    },
    {
      "name": "SQL_SERVICE_ACCOUNT_USER",
      "value": "Administrator@ntnxlab.local",
      "secure": false,
      "description": "Sql service account username"
    },
    {
      "name": "SQL_SERVICE_ACCOUNT_PASSWORD",
      "value": "nutanix/4u",
      "secure": false,
      "description": "Sql service account password"
    },
    {
      "name": "ALLOW_SERVICE_ACCOUNT_OVERRRIDE",
      "value": false,
      "secure": false,
      "description": "Allow override of sql service account in provisioning workflows"
    },
    {
      "name": "ERA_WORKER_SERVICE_USER",
      "value": "Administrator@ntnxlab.local",
      "secure": false,
      "description": "Era worker service account username"
    },
    {
      "name": "ERA_WORKER_SERVICE_PASSWORD",
      "value": "nutanix/4u",
      "secure": false,
      "description": "Era worker service account password"
    },
    {
      "name": "RESTART_SERVICE",
      "value": "",
      "secure": false,
      "description": "Restart sql service on the dbservers"
    },
    {
      "name": "UPDATE_CREDENTIALS_IN_DBSERVERS",
      "value": "true",
      "secure": false,
      "description": "Update the credentials in all the dbservers"
    }
  ],
  "name": "NTNXLAB"
}
EOF
)

  _ntnxlab_domain_profile_id=$(curl ${CURL_HTTP_OPTS} -u ${ERA_USER}:${ERA_PASSWORD} -X POST "https://${ERA_HOST}/era/v0.9/profiles" --data "${HTTP_JSON_BODY}" | jq -r '.id' | tr -d \")

log "Created NTNXLAB Domain Profile with ID |${_ntnxlab_domain_profile_id}|"

##  Create the ORACLE_SMALL_PARAMS Parameters Profile inside Era ##
log "Create the ORACLE_SMALL_PARAMS Parameters Profile"

HTTP_JSON_BODY=$(cat <<EOF
{
  "engineType": "oracle_database",
  "type": "Database_Parameter",
  "topology": "ALL",
  "dbVersion": "ALL",
  "systemProfile": false,
  "properties": [
    {
      "name": "MEMORY_TARGET",
      "value": 4096,
      "description": "Total Memory (MiB): Total memory (AKA MEMORY_TARGET) specifies the Oracle systemwide usable memory. The database tunes memory to the total memory value, reducing or enlarging the SGA and PGA as needed."
    },
    {
      "name": "SGA_TARGET",
      "value": "",
      "description": "SGA (MiB): Provide a value here to disable automatic shared memory management. Providing a value enables you to determine how the SGA memory is distributed among the SGA memory components."
    },
    {
      "name": "PGA_AGGREGATE_TARGET",
      "value": "",
      "description": "PGA (MiB): Provide a value here to disable automatic shared memory management. Providing a value enables you to determine how the PGA memory is distributed among the PGA memory components."
    },
    {
      "name": "SHARED_SERVERS",
      "value": "0",
      "description": "Number of shared servers: Specify this number when the connection mode is set to 'shared'"
    },
    {
      "name": "DB_BLOCK_SIZE",
      "value": "8",
      "description": "Block Size (KiB): Oracle Database data is stored in data blocks of the size specified. One data block corresponds to a specific number of bytes of physical space on the disk. Selecting a block size other than the default 8 kilobytes (KiB) value requires advanced knowledge and should be done only when absolutely required."
    },
    {
      "name": "PROCESSES",
      "value": "300",
      "description": "Number of processes: Specify the maximum number of processes that can simultaneously connect to the database. Enter a number or accept the default value of 300. The default value for this parameter is appropriate for many environments. The value you select should allow for all background processes, user processes, and parallel execution processes."
    },
    {
      "name": "TEMP_TABLESPACE",
      "value": "256",
      "description": "Temp Tablespace (MiB)"
    },
    {
      "name": "UNDO_TABLESPACE",
      "value": 256,
      "description": "Undo Tablespace (MiB)"
    },
    {
      "name": "NLS_LANGUAGE",
      "value": "AMERICAN",
      "description": "Default Language: The default language determines how the database supports locale-sensitive information such as day and month abbreviations, default sorting sequence for character data, and reading direction (left to right ir right to left)."
    },
    {
      "name": "NLS_TERRITORY",
      "value": "AMERICA",
      "description": "Default Territory: Select the name of the territory whose conventions are to be followed for day and week numbering or accept the default. The default territory also establishes the default date format, the default decimal character and group separator, and the default International Standardization Organization (ISO) and local currency symbols."
    }
  ],
  "name": "ORACLE_SMALL_PARAMS"
}
EOF
)

  _oracle_param_profile_id=$(curl ${CURL_HTTP_OPTS} -u ${ERA_USER}:${ERA_PASSWORD} -X POST "https://${ERA_HOST}/era/v0.9/profiles" --data "${HTTP_JSON_BODY}" | jq -r '.id' | tr -d \")

log "Created ORACLE_SMALL_PARAMS Parameters Profile with ID |${_oracle_param_profile_id}|"

## Get the Super Admin Role ID ##
log "Getting the Super Admin Role ID"

  _role_id=$(curl ${CURL_HTTP_OPTS} -u ${ERA_USER}:${ERA_PASSWORD} -X GET "https://${ERA_HOST}/era/v0.9/roles" --data '{}' | jq '.[] | select(.name == "Super Admin") | .id' | tr -d \")

log "Super Admin Role ID |${_role_id}|"

## Create Users with Super Admin Role ##
log "Creating Era Users with Super Admin Role"

for _user in "${USERS[@]}" ; do

log "Creating l${_user}"

HTTP_JSON_BODY=$(cat <<EOF
{
  "internalUser": false,
  "roles": [
    "${_role_id}"
  ],
  "isExternalAuth": false,
  "username": "${_user}",
  "password": "${ERA_PASSWORD}",
  "passwordExpired": true
}
EOF
)

  _user_id=$(curl ${CURL_HTTP_OPTS} -u ${ERA_USER}:${ERA_PASSWORD} -X POST "https://${ERA_HOST}/era/v0.9/users" --data "${HTTP_JSON_BODY}" | jq -r '.id' | tr -d \")

log "Created User ${_user} with ID |${_user_id}|"

done

log "Era Config Complete"

#set +x

}

###############################################################################################################################################################################
# Routine to Create a Project in the Calm part
###############################################################################################################################################################################

function pc_project() {
  local _name="BootcampInfra"
  local _count
  local _user_group_uuid
  local _role="Project Admin"
  local _role_uuid
  local _pc_account_uuid
  local _nw_name="${NW1_NAME}"
  local _nw_uuid
  local CURL_HTTP_OPTS=" --max-time 25 --silent --header Content-Type:application/json --header Accept:application/json  --insecure "

set -x

# Get the Network UUIDs
log "-------------------------------------"
log "Get cluster network UUID"

_nw_uuid=$(curl ${CURL_HTTP_OPTS} --request POST 'https://localhost:9440/api/nutanix/v3/subnets/list' --user ${PRISM_ADMIN}:${PE_PASSWORD} --data '{"kind":"subnet","filter": "name==Primary"}' | jq -r '.entities[] | .metadata.uuid' | tr -d \")

log "NW UUID = ${_nw_uuid}"

# Get the Role UUIDs
log "-------------------------------------"
log "Get Role UUID"

_role_uuid=$(curl ${CURL_HTTP_OPTS}--request POST 'https://localhost:9440/api/nutanix/v3/roles/list' --user ${PRISM_ADMIN}:${PE_PASSWORD} --data '{"kind":"role","filter":"name==Project Admin"}' | jq -r '.entities[] | .metadata.uuid' | tr -d \")

log "Role UUID = ${_role_uuid}"

# Get the PC Account UUIDs
log "-------------------------------------"
log "Get PC Account  UUID"

_pc_account_uuid=$(curl ${CURL_HTTP_OPTS} --request POST 'https://localhost:9440/api/nutanix/v3/accounts/list' --user ${PRISM_ADMIN}:${PE_PASSWORD} --data '{"kind":"account","filter":"type==nutanix_pc"}' | jq -r '.entities[] | .metadata.uuid' | tr -d \")

log "PC Account UUID = ${_pc_account_uuid}"

## Create Project ##
log "-------------------------------------"
log "Create BootcampInfra Project ..."

HTTP_JSON_BODY=$(cat <<EOF
{
   "api_version":"3.1.0",
   "metadata":{
      "kind":"project"
   },
   "spec":{
      "name":"BootcampInfra",
      "resources":{
         "account_reference_list":[
            {
               "uuid":"${_pc_account_uuid}",
               "kind":"account",
               "name":"nutanix_pc"
            }
         ],
         "subnet_reference_list":[
            {
               "kind":"subnet",
               "name": "Primary",
        	   "uuid": "${_nw_uuid}"
            }
         ],
         "user_reference_list":[
            {
               "kind":"user",
               "name":"admin",
               "uuid":"00000000-0000-0000-0000-000000000000"
            }
         ],
         "environment_reference_list":[]
      }
   }
}
EOF
)

  echo "Creating Calm Project Create Now"
  echo $HTTP_JSON_BODY

  _task_id=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST  --data "${HTTP_JSON_BODY}" 'https://localhost:9440/api/nutanix/v3/projects' | jq -r '.status.execution_context.task_uuid' | tr -d \")

  log "Task uuid for the Calm Project Create is " $_task_id " ....."
  #Sleep 60

  #_task_id=$(curl ${CURL_HTTP_OPTS} --request POST 'https://localhost:9440/api/nutanix/v3/projects_internal' --user ${PRISM_ADMIN}:${PE_PASSWORD} --data "${_http_body}" | jq -r '.status.execution_context.task_uuid' | tr -d \")

  if [ -z "$_task_id" ]; then
       log "Calm Project Create has encountered an error..."
  else
       log "Calm Project Create started.."
       set _loops=0 # Reset the loop counter so we restart the amount of loops we need to run
       # Run the progess checker
       loop
  fi

  log "_ssp_connect=|${_ssp_connect}|"

set +x

}

###############################################################################################################################################################################
# Routine to upload Citrix Calm Blueprint and set variables
###############################################################################################################################################################################

function upload_citrix_calm_blueprint() {
  local DIRECTORY="/home/nutanix/citrix"
  local BLUEPRINT=${Citrix_Blueprint}
  local CALM_PROJECT="BootcampInfra"
  local DOMAIN=${AUTH_FQDN}
  local AD_IP=${AUTH_HOST}
  local PE_IP=${PE_HOST}
  local DDC_IP=${CITRIX_DDC_HOST}
  local NutanixAcropolisPlugin="none"
  local CVM_NETWORK=${NW1_NAME}
  local NETWORK_NAME=${NW1_NAME}
  local VLAN_NAME=${NW1_VLAN}
  local BPG_RKTOOLS_URL="none"
  local NutanixAcropolis_Installed_Path="none"
  local LOCAL_PASSWORD="nutanix/4u"
  local DOMAIN_CREDS_PASSWORD="nutanix/4u"
  local PE_CREDS_PASSWORD="${PE_PASSWORD}"
  local SQL_CREDS_PASSWORD="nutanix/4u"
  local DOWNLOAD_BLUEPRINTS
  local NETWORK_UUID
  local SERVER_IMAGE="Windows2016.qcow2"
  local SERVER_IMAGE_UUID
  local CITRIX_IMAGE="Citrix_Virtual_Apps_and_Desktops_7_1912.iso"
  local CITRIX_IMAGE_UUID
  local CURL_HTTP_OPTS="--max-time 25 --silent -k --header Content-Type:application/json --header Accept:application/json  --insecure"
  local _loops="0"
  local _maxtries="75"


  echo "Starting Citrix Blueprint Deployment"

  mkdir $DIRECTORY

  echo "Getting Server Image UUID"
  #Getting the IMAGE_UUID
  _loops="0"
  _maxtries="75"

  SERVER_IMAGE_UUID_CHECK=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST -d '{}' 'https://localhost:9440/api/nutanix/v3/images/list' | grep 'Windows2016.qcow2' | wc -l)
  # The response should be a Task UUID
  while [[ $SERVER_IMAGE_UUID_CHECK -ne 1 && $_loops -lt $_maxtries ]]; do
      log "Image not yet uploaded. $_loops/$_maxtries... sleeping 60 seconds"
      sleep 60
      SERVER_IMAGE_UUID_CHECK=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST -d '{}' 'https://localhost:9440/api/nutanix/v3/images/list' | grep 'Windows2016.qcow2' | wc -l)
      (( _loops++ ))
  done
  if [[ $_loops -lt $_maxtries ]]; then
      log "Image has been uploaded."
      SERVER_IMAGE_UUID=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST --data '{"kind":"image","filter": "name==Windows2016.qcow2"}' 'https://localhost:9440/api/nutanix/v3/images/list' | jq -r '.entities[] | .metadata.uuid' | tr -d \")
  else
      log "Image is not upload, please check."
  fi

  echo "Server Image UUID = $SERVER_IMAGE_UUID"
  echo "-----------------------------------------"

  sleep 30

  echo "Getting Citrix Image UUID"
  #Getting the IMAGE_UUID
  _loops="0"
  _maxtries="75"

  CITRIX_IMAGE_UUID_CHECK=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST -d '{}' 'https://localhost:9440/api/nutanix/v3/images/list' | grep 'Citrix_Virtual_Apps_and_Desktops_7_1912.iso' | wc -l)
  while [[ $CITRIX_IMAGE_UUID_CHECK -ne 1 && $_loops -lt $_maxtries ]]; do
      log "Image not yet uploaded. $_loops/$_maxtries... sleeping 60 seconds"
      sleep 60
      CITRIX_IMAGE_UUID_CHECK=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST -d '{}' 'https://localhost:9440/api/nutanix/v3/images/list' | grep 'Citrix_Virtual_Apps_and_Desktops_7_1912.iso' | wc -l)
      (( _loops++ ))
  done
  if [[ $_loops -lt $_maxtries ]]; then
      log "Image has been uploaded."
      CITRIX_IMAGE_UUID=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST --data '{"kind":"image","filter": "name==Citrix_Virtual_Apps_and_Desktops_7_1912.iso"}' 'https://localhost:9440/api/nutanix/v3/images/list' | jq -r '.entities[] | .metadata.uuid' | tr -d \")
  else
      log "Image is not upload, please check."
  fi

  echo "Citrix Image UUID = $CITRIX_IMAGE_UUID"
  echo "-----------------------------------------"

  sleep 30

  echo "Getting Network UUID"

  NETWORK_UUID=$(curl ${CURL_HTTP_OPTS} --request POST 'https://localhost:9440/api/nutanix/v3/subnets/list' --user ${PRISM_ADMIN}:${PE_PASSWORD} --data '{"kind":"subnet","filter": "name==Primary"}' | jq -r '.entities[] | .metadata.uuid' | tr -d \")

  echo "NETWORK UUID = $NETWORK_UUID"
  echo "-----------------------------------------"

  # download the blueprint
  DOWNLOAD_BLUEPRINTS=$(curl -L ${BLUEPRINT_URL}${BLUEPRINT} -o ${DIRECTORY}/${BLUEPRINT})
  log "Downloading ${BLUEPRINT} | BLUEPRINT_URL ${BLUEPRINT_URL}|${DOWNLOAD_BLUEPRINTS}"

  # ensure the directory that contains the blueprints to be imported is not empty
  if [[ $(ls -l "$DIRECTORY"/*.json) == *"No such file or directory"* ]]; then
      echo "There are no .json files found in the directory provided."
      exit 0
  fi

  if [ $CALM_PROJECT != 'none' ]; then

      # curl command needed:
      # curl -s -k -X POST https://10.42.7.39:9440/api/nutanix/v3/projects/list -H 'Content-Type: application/json' --user admin:techX2019! -d '{"kind": "project", "filter": "name==default"}' | jq -r '.entities[].metadata.uuid'

      # make API call and store project_uuid
      project_uuid=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST --data '{"kind":"project", "filter":"name==BootcampInfra"}' 'https://localhost:9440/api/nutanix/v3/projects/list' | jq -r '.entities[].metadata.uuid')

      echo "Projet UUID = $project_uuid"

      if [ -z "$project_uuid" ]; then
          # project wasn't found
          # exit at this point as we don't want to assume all blueprints should then hit the 'default' project
          echo "Project $CALM_PROJECT was not found. Please check the name and retry."
          exit 0
      else
          echo "Project $CALM_PROJECT exists..."
      fi
  fi


  # update the user with script progress...

  echo "Starting blueprint updates and then Uploading to Calm..."

  JSONFile="${DIRECTORY}/${BLUEPRINT}"

  echo "Currently updating blueprint $JSONFile..."


  # NOTE: bash doesn't do in place editing so we need to use a temp file and overwrite the old file with new changes for every blueprint
  tmp=$(mktemp)

  # ADD PROJECT (affects all BPs being imported) if no project was specified on the command line, we've already pre-set the project variable to 'none' if a project was specified, we need to add it into the JSON data
  if [ $CALM_PROJECT != 'none' ]; then
      # add the new atributes to the JSON and overwrite the old JSON file with the new one
      $(jq --arg proj $CALM_PROJECT --arg proj_uuid $project_uuid '.metadata+={"project_reference":{"kind":$proj,"uuid":$proj_uuid}}' $JSONFile >"$tmp" && mv "$tmp" $JSONFile)
  fi

  # REMOVE the "status" and "product_version" keys (if they exist) from the JSON data this is included on export but is invalid on import. (affects all BPs being imported)
  tmp_removal=$(mktemp)
  $(jq 'del(.status) | del(.product_version)' $JSONFile >"$tmp_removal" && mv "$tmp_removal" $JSONFile)

  # GET BP NAME (affects all BPs being imported)
  # if this fails, it's either a corrupt/damaged/edited blueprint JSON file or not a blueprint file at all
  blueprint_name_quotes=$(jq '(.spec.name)' $JSONFile)
  blueprint_name="${blueprint_name_quotes%\"}" # remove the suffix "
  blueprint_name="${blueprint_name#\"}" # will remove the prefix "

  if [ $blueprint_name == 'null' ]; then
      echo "Unprocessable JSON file found. Is this definitely a Nutanix Calm blueprint file?"
      exit 0
  else
      # got the blueprint name means it is probably a valid blueprint file, we can now continue the upload
      echo "Uploading the updated blueprint: $blueprint_name..."

      path_to_file=$JSONFile
      bp_name=$blueprint_name
      project_uuid=$project_uuid

      upload_result=$(curl -s -k --insecure --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST -F file=@$path_to_file -F name=$bp_name -F project_uuid=$project_uuid "https://localhost:9440/api/nutanix/v3/blueprints/import_file")

      #if the upload_result var is not empty then let's say it was succcessful
      if [ -z "$upload_result" ]; then
          echo "Upload for $bp_name did not finish."
      else
          echo "Upload for $bp_name finished."
          echo "-----------------------------------------"
          # echo "Result: $upload_result"
      fi
  fi

  echo "Finished uploading ${BLUEPRINT}!"

  #Getting the Blueprint UUID
  CITRIX_BLUEPRINT_UUID=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST --data '{"kind":"blueprint","filter": "name==CitrixBootcampInfra"}' 'https://localhost:9440/api/nutanix/v3/blueprints/list' | jq -r '.entities[] | .metadata.uuid' | tr -d \")

  echo "Citrix Blueprint UUID = $CITRIX_BLUEPRINT_UUID"

  echo "Update Blueprint and writing to temp file"
  echo "${CALM_PROJECT} network UUID: ${project_uuid}"
  echo "DOMAIN=${DOMAIN}"
  echo "AD_IP=${AD_IP}"
  echo "PE_IP=${PE_IP}"
  echo "DDC_IP=${DDC_IP}"
  echo "CVM_NETWORK=${CVM_NETWORK}"
  echo "SERVER_IMAGE=${SERVER_IMAGE}"
  echo "SERVER_IMAGE_UUID=${SERVER_IMAGE_UUID}"
  echo "CITRIX_IMAGE=${CITRIX_IMAGE}"
  echo "CITRIX_IMAGE_UUID=${CITRIX_IMAGE_UUID}"
  echo "NETWORK_UUID=${NETWORK_UUID}"

  DOWNLOADED_JSONFile="${BLUEPRINT}-${CITRIX_BLUEPRINT_UUID}.json"
  UPDATED_JSONFile="${BLUEPRINT}-${CITRIX_BLUEPRINT_UUID}-updated.json"

  # GET The Blueprint so it can be updated
  curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X GET -d '{}' "https://localhost:9440/api/nutanix/v3/blueprints/${CITRIX_BLUEPRINT_UUID}" > ${DOWNLOADED_JSONFile}

  cat $DOWNLOADED_JSONFile \
  | jq -c 'del(.status)' \
  | jq -c -r "(.spec.resources.app_profile_list[0].variable_list[0].value = \"$DOMAIN\")" \
  | jq -c -r "(.spec.resources.app_profile_list[0].variable_list[1].value = \"$AD_IP\")" \
  | jq -c -r "(.spec.resources.app_profile_list[0].variable_list[2].value = \"$PE_IP\")" \
  | jq -c -r "(.spec.resources.app_profile_list[0].variable_list[6].value = \"$DDC_IP\")" \
  | jq -c -r "(.spec.resources.app_profile_list[0].variable_list[4].value = \"$CVM_NETWORK\")" \
  | jq -c -r "(.spec.resources.substrate_definition_list[0].create_spec.resources.disk_list[0].data_source_reference.name = \"$SERVER_IMAGE\")" \
  | jq -c -r "(.spec.resources.substrate_definition_list[0].create_spec.resources.disk_list[0].data_source_reference.uuid = \"$SERVER_IMAGE_UUID\")" \
  | jq -c -r "(.spec.resources.substrate_definition_list[0].create_spec.resources.disk_list[1].data_source_reference.name = \"$CITRIX_IMAGE\")" \
  | jq -c -r "(.spec.resources.substrate_definition_list[0].create_spec.resources.disk_list[1].data_source_reference.uuid = \"$CITRIX_IMAGE_UUID\")" \
  | jq -c -r "(.spec.resources.substrate_definition_list[].create_spec.resources.nic_list[].subnet_reference.name = \"$NETWORK_NAME\")" \
  | jq -c -r "(.spec.resources.substrate_definition_list[].create_spec.resources.nic_list[].subnet_reference.uuid = \"$NETWORK_UUID\")" \
  | jq -c -r "(.spec.resources.credential_definition_list[0].secret.value = \"$LOCAL_PASSWORD\")" \
  | jq -c -r '(.spec.resources.credential_definition_list[0].secret.attrs.is_secret_modified = "true")' \
  | jq -c -r "(.spec.resources.credential_definition_list[1].secret.value = \"$DOMAIN_CREDS_PASSWORD\")" \
  | jq -c -r '(.spec.resources.credential_definition_list[1].secret.attrs.is_secret_modified = "true")' \
  | jq -c -r "(.spec.resources.credential_definition_list[2].secret.value = \"$PE_CREDS_PASSWORD\")" \
  | jq -c -r '(.spec.resources.credential_definition_list[2].secret.attrs.is_secret_modified = "true")' \
  | jq -c -r "(.spec.resources.credential_definition_list[3].secret.value = \"$SQL_CREDS_PASSWORD\")" \
  | jq -c -r '(.spec.resources.credential_definition_list[3].secret.attrs.is_secret_modified = "true")' \
  > $UPDATED_JSONFile

  echo "Saving Credentials Edits with PUT"

  curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X PUT -d @$UPDATED_JSONFile "https://localhost:9440/api/nutanix/v3/blueprints/${CITRIX_BLUEPRINT_UUID}"

  echo "Finished Updating Credentials"

  # GET The Blueprint payload
  curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X GET -d '{}' "https://localhost:9440/api/nutanix/v3/blueprints/${CITRIX_BLUEPRINT_UUID}" | jq 'del(.status, .spec.name) | .spec += {"application_name": "Citrix Infra", "app_profile_reference": {"uuid": .spec.resources.app_profile_list[0].uuid, "kind": "app_profile" }}' > set_blueprint_response_file.json

  # Launch the BLUEPRINT

  echo "Launching the Era Server Application"

  curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST -d @set_blueprint_response_file.json "https://localhost:9440/api/nutanix/v3/blueprints/${CITRIX_BLUEPRINT_UUID}/launch"

  echo "Finished Launching the Citrix Infra Application"

}

###############################################################################################################################################################################
# Routine to upload Era Calm Blueprint and set variables
###############################################################################################################################################################################

function upload_era_calm_blueprint() {
  local DIRECTORY="/home/nutanix/era"
  local BLUEPRINT=${ERA_Blueprint}
  local CALM_PROJECT="BootcampInfra"
  local ERA_IP=${ERA_HOST}
  local PE_IP=${PE_HOST}
  local CLSTR_NAME="none"
  local CTR_UUID=${_storage_default_uuid}
  local CTR_NAME=${STORAGE_DEFAULT}
  local NETWORK_NAME=${NW1_NAME}
  local VLAN_NAME=${NW1_VLAN}
  local ERAADMIN_PASSWORD="nutanix/4u"
  local PE_CREDS_PASSWORD="${PE_PASSWORD}"
  #local ERACLI_PASSWORD=$(awk '{printf "%s\\n", $0}' ${DIRECTORY}/${CALM_RSA_KEY_FILE})
  local DOWNLOAD_BLUEPRINTS
  local ERA_IMAGE="ERA-Server-build-1.2.1.qcow2"
  local ERA_IMAGE_UUID
  local CURL_HTTP_OPTS="--max-time 25 --silent -k --header Content-Type:application/json --header Accept:application/json  --insecure"
  local _loops="0"
  local _maxtries="75"


  echo "Starting Era Blueprint Deployment"

  mkdir $DIRECTORY

  echo "Getting Era Image UUID"
  #Getting the IMAGE_UUID -- WHen changing the image make sure to change in the name filter
  _loops="0"
  _maxtries="75"

  ERA_IMAGE_UUID_CHECK=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST -d '{}' 'https://localhost:9440/api/nutanix/v3/images/list' | grep 'ERA-Server-build-1.2.1.qcow2' | wc -l)
  # The response should be a Task UUID
  while [[ $ERA_IMAGE_UUID_CHECK -ne 1 && $_loops -lt $_maxtries ]]; do
      log "Image not yet uploaded. $_loops/$_maxtries... sleeping 60 seconds"
      sleep 60
      ERA_IMAGE_UUID_CHECK=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST -d '{}' 'https://localhost:9440/api/nutanix/v3/images/list' | grep 'ERA-Server-build-1.2.1.qcow2' | wc -l)
      (( _loops++ ))
  done
  if [[ $_loops -lt $_maxtries ]]; then
      log "Image has been uploaded."
      ERA_IMAGE_UUID=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST --data '{"kind":"image","filter": "name==ERA-Server-build-1.2.1.qcow2"}' 'https://localhost:9440/api/nutanix/v3/images/list' | jq -r '.entities[] | .metadata.uuid' | tr -d \")
  else
      log "Image is not upload, please check."
  fi


  echo "ERA Image UUID = $ERA_IMAGE_UUID"
  echo "-----------------------------------------"

  echo "Getting NETWORK UUID"

  NETWORK_UUID=$(curl ${CURL_HTTP_OPTS} --request POST 'https://localhost:9440/api/nutanix/v3/subnets/list' --user ${PRISM_ADMIN}:${PE_PASSWORD} --data '{"kind":"subnet","filter": "name==Primary"}' | jq -r '.entities[] | .metadata.uuid' | tr -d \")

  echo "NETWORK UUID = $NETWORK_UUID"
  echo "-----------------------------------------"

  # download the blueprint
  DOWNLOAD_BLUEPRINTS=$(curl -L ${BLUEPRINT_URL}${BLUEPRINT} -o ${DIRECTORY}/${BLUEPRINT})
  log "Downloading ${BLUEPRINT} | BLUEPRINT_URL ${BLUEPRINT_URL}|${DOWNLOAD_BLUEPRINTS}"

  # ensure the directory that contains the blueprints to be imported is not empty
  if [[ $(ls -l "$DIRECTORY"/*.json) == *"No such file or directory"* ]]; then
      echo "There are no .json files found in the directory provided."
      exit 0
  fi

  if [ $CALM_PROJECT != 'none' ]; then

      # curl command needed:
      # curl -s -k -X POST https://10.42.7.39:9440/api/nutanix/v3/projects/list -H 'Content-Type: application/json' --user admin:techX2019! -d '{"kind": "project", "filter": "name==default"}' | jq -r '.entities[].metadata.uuid'

      # make API call and store project_uuid
      project_uuid=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST --data '{"kind":"project", "filter":"name==BootcampInfra"}' 'https://localhost:9440/api/nutanix/v3/projects/list' | jq -r '.entities[].metadata.uuid')

      echo "Projet UUID = $project_uuid"

      if [ -z "$project_uuid" ]; then
          # project wasn't found
          # exit at this point as we don't want to assume all blueprints should then hit the 'default' project
          echo "Project $CALM_PROJECT was not found. Please check the name and retry."
          exit 0
      else
          echo "Project $CALM_PROJECT exists..."
      fi
  fi

  # update the user with script progress...

  echo "Starting blueprint updates and then Uploading to Calm..."

  # read the entire JSON file from the directory
  JSONFile="${DIRECTORY}/${BLUEPRINT}"

  echo "Currently updating blueprint $JSONFile..."

  # NOTE: bash doesn't do in place editing so we need to use a temp file and overwrite the old file with new changes for every blueprint
  tmp=$(mktemp)

  # ADD PROJECT , we need to add it into the JSON data
  if [ $CALM_PROJECT != 'none' ]; then
      # add the new atributes to the JSON and overwrite the old JSON file with the new one
      $(jq --arg proj $CALM_PROJECT --arg proj_uuid $project_uuid '.metadata+={"project_reference":{"kind":$proj,"uuid":$proj_uuid}}' $JSONFile >"$tmp" && mv "$tmp" $JSONFile)
  fi

  # REMOVE the "status" and "product_version" keys (if they exist) from the JSON data this is included on export but is invalid on import. (affects all BPs being imported)
  tmp_removal=$(mktemp)
  $(jq 'del(.status) | del(.product_version)' $JSONFile >"$tmp_removal" && mv "$tmp_removal" $JSONFile)

  # GET BP NAME (affects all BPs being imported)
  # if this fails, it's either a corrupt/damaged/edited blueprint JSON file or not a blueprint file at all
  blueprint_name_quotes=$(jq '(.spec.name)' $JSONFile)
  blueprint_name="${blueprint_name_quotes%\"}" # remove the suffix "
  blueprint_name="${blueprint_name#\"}" # will remove the prefix "

  if [ $blueprint_name == 'null' ]; then
      echo "Unprocessable JSON file found. Is this definitely a Nutanix Calm blueprint file?"
      exit 0
  else
      # got the blueprint name means it is probably a valid blueprint file, we can now continue the upload
      echo "Uploading the updated blueprint: $blueprint_name..."

      path_to_file=$JSONFile
      bp_name=$blueprint_name
      project_uuid=$project_uuid

      upload_result=$(curl -s -k --insecure --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST https://localhost:9440/api/nutanix/v3/blueprints/import_file -F file=@$path_to_file -F name=$bp_name -F project_uuid=$project_uuid)

      #if the upload_result var is not empty then let's say it was succcessful
      if [ -z "$upload_result" ]; then
          echo "Upload for $bp_name did not finish."
      else
          echo "Upload for $bp_name finished."
          echo "-----------------------------------------"
          # echo "Result: $upload_result"
      fi
  fi

  echo "Finished uploading ${BLUEPRINT}!"

  #Getting the Blueprint UUID
  ERA_BLUEPRINT_UUID=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST --data '{"kind":"blueprint","filter": "name==EraServerDeployment"}' 'https://localhost:9440/api/nutanix/v3/blueprints/list' | jq -r '.entities[] | .metadata.uuid' | tr -d \")

  echo "ERA Blueprint UUID = $ERA_BLUEPRINT_UUID"

  echo "Update Blueprint and writing to temp file"

  echo "${CALM_PROJECT} network UUID: ${project_uuid}"
  echo "ERA_IP=${ERA_IP}"
  echo "PE_IP=${PE_IP}"
  echo "ERA_IMAGE=${ERA_IMAGE}"
  echo "ERA_IMAGE_UUID=${ERA_IMAGE_UUID}"
  echo "NETWORK_UUID=${NETWORK_UUID}"

  DOWNLOADED_JSONFile="${BLUEPRINT}-${ERA_BLUEPRINT_UUID}.json"
  UPDATED_JSONFile="${BLUEPRINT}-${ERA_BLUEPRINT_UUID}-updated.json"

  # GET The Blueprint so it can be updated
  curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X GET -d '{}' "https://localhost:9440/api/nutanix/v3/blueprints/${ERA_BLUEPRINT_UUID}" > ${DOWNLOADED_JSONFile}

  cat $DOWNLOADED_JSONFile \
  | jq -c 'del(.status)' \
  | jq -c -r "(.spec.resources.app_profile_list[0].variable_list[0].value = \"$ERA_IP\")" \
  | jq -c -r "(.spec.resources.substrate_definition_list[0].create_spec.resources.disk_list[0].data_source_reference.name = \"$ERA_IMAGE\")" \
  | jq -c -r "(.spec.resources.substrate_definition_list[0].create_spec.resources.disk_list[0].data_source_reference.uuid = \"$ERA_IMAGE_UUID\")" \
  | jq -c -r "(.spec.resources.substrate_definition_list[].create_spec.resources.nic_list[].subnet_reference.name = \"$NETWORK_NAME\")" \
  | jq -c -r "(.spec.resources.substrate_definition_list[].create_spec.resources.nic_list[].subnet_reference.uuid = \"$NETWORK_UUID\")" \
  | jq -c -r "(.spec.resources.credential_definition_list[0].secret.value = \"$ERAADMIN_PASSWORD\")" \
  | jq -c -r '(.spec.resources.credential_definition_list[0].secret.attrs.is_secret_modified = "true")' \
  | jq -c -r "(.spec.resources.credential_definition_list[1].secret.value = \"$PE_CREDS_PASSWORD\")" \
  | jq -c -r '(.spec.resources.credential_definition_list[1].secret.attrs.is_secret_modified = "true")' \
  | jq -c -r "(.spec.resources.credential_definition_list[2].secret.value=\"-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEAii7qFDhVadLx5lULAG/ooCUTA/ATSmXbArs+GdHxbUWd/bNG\nZCXnaQ2L1mSVVGDxfTbSaTJ3En3tVlMtD2RjZPdhqWESCaoj2kXLYSiNDS9qz3SK\n6h822je/f9O9CzCTrw2XGhnDVwmNraUvO5wmQObCDthTXc72PcBOd6oa4ENsnuY9\nHtiETg29TZXgCYPFXipLBHSZYkBmGgccAeY9dq5ywiywBJLuoSovXkkRJk3cd7Gy\nhCRIwYzqfdgSmiAMYgJLrz/UuLxatPqXts2D8v1xqR9EPNZNzgd4QHK4of1lqsNR\nuz2SxkwqLcXSw0mGcAL8mIwVpzhPzwmENC5OrwIBJQKCAQB++q2WCkCmbtByyrAp\n6ktiukjTL6MGGGhjX/PgYA5IvINX1SvtU0NZnb7FAntiSz7GFrODQyFPQ0jL3bq0\nMrwzRDA6x+cPzMb/7RvBEIGdadfFjbAVaMqfAsul5SpBokKFLxU6lDb2CMdhS67c\n1K2Hv0qKLpHL0vAdEZQ2nFAMWETvVMzl0o1dQmyGzA0GTY8VYdCRsUbwNgvFMvBj\n8T/svzjpASDifa7IXlGaLrXfCH584zt7y+qjJ05O1G0NFslQ9n2wi7F93N8rHxgl\nJDE4OhfyaDyLL1UdBlBpjYPSUbX7D5NExLggWEVFEwx4JRaK6+aDdFDKbSBIidHf\nh45NAoGBANjANRKLBtcxmW4foK5ILTuFkOaowqj+2AIgT1ezCVpErHDFg0bkuvDk\nQVdsAJRX5//luSO30dI0OWWGjgmIUXD7iej0sjAPJjRAv8ai+MYyaLfkdqv1Oj5c\noDC3KjmSdXTuWSYNvarsW+Uf2v7zlZlWesTnpV6gkZH3tX86iuiZAoGBAKM0mKX0\nEjFkJH65Ym7gIED2CUyuFqq4WsCUD2RakpYZyIBKZGr8MRni3I4z6Hqm+rxVW6Dj\nuFGQe5GhgPvO23UG1Y6nm0VkYgZq81TraZc/oMzignSC95w7OsLaLn6qp32Fje1M\nEz2Yn0T3dDcu1twY8OoDuvWx5LFMJ3NoRJaHAoGBAJ4rZP+xj17DVElxBo0EPK7k\n7TKygDYhwDjnJSRSN0HfFg0agmQqXucjGuzEbyAkeN1Um9vLU+xrTHqEyIN/Jqxk\nhztKxzfTtBhK7M84p7M5iq+0jfMau8ykdOVHZAB/odHeXLrnbrr/gVQsAKw1NdDC\nkPCNXP/c9JrzB+c4juEVAoGBAJGPxmp/vTL4c5OebIxnCAKWP6VBUnyWliFhdYME\nrECvNkjoZ2ZWjKhijVw8Il+OAjlFNgwJXzP9Z0qJIAMuHa2QeUfhmFKlo4ku9LOF\n2rdUbNJpKD5m+IRsLX1az4W6zLwPVRHp56WjzFJEfGiRjzMBfOxkMSBSjbLjDm3Z\niUf7AoGBALjvtjapDwlEa5/CFvzOVGFq4L/OJTBEBGx/SA4HUc3TFTtlY2hvTDPZ\ndQr/JBzLBUjCOBVuUuH3uW7hGhW+DnlzrfbfJATaRR8Ht6VU651T+Gbrr8EqNpCP\ngmznERCNf9Kaxl/hlyV5dZBe/2LIK+/jLGNu9EJLoraaCBFshJKF\n-----END RSA PRIVATE KEY-----\n\")" \
  | jq -c -r '(.spec.resources.credential_definition_list[2].secret.attrs.is_secret_modified = "true")' \
  > $UPDATED_JSONFile

  echo "Saving Credentials Edits with PUT"

  curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X PUT -d @$UPDATED_JSONFile "https://localhost:9440/api/nutanix/v3/blueprints/${ERA_BLUEPRINT_UUID}"

  echo "Finished Updating Credentials"

  # GET The Blueprint payload
  curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X GET -d '{}' "https://localhost:9440/api/nutanix/v3/blueprints/${ERA_BLUEPRINT_UUID}" | jq 'del(.status, .spec.name) | .spec += {"application_name": "Era Server", "app_profile_reference": {"uuid": .spec.resources.app_profile_list[0].uuid, "kind": "app_profile" }}' > set_blueprint_response_file.json

  # Launch the BLUEPRINT

  echo "Launching the Era Server Application"

  curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST -d @set_blueprint_response_file.json "https://localhost:9440/api/nutanix/v3/blueprints/${ERA_BLUEPRINT_UUID}/launch"

  echo "Finished Launching the Era Server Application"

}

###############################################################################################################################################################################
# Routine to upload Karbon Calm Blueprint and set variables
###############################################################################################################################################################################

function upload_karbon_calm_blueprint() {
  local DIRECTORY="/home/nutanix/karbon"
  local BLUEPRINT=${Karbon_Blueprint}
  local CALM_PROJECT="BootcampInfra"
  local KARBON_IMAGE='ntnx-0.4'
  local PE_IP=${PE_HOST}
  local CLSTR_NAME="none"
  local CTR_UUID=${_storage_default_uuid}
  local CTR_NAME=${STORAGE_DEFAULT}
  local NETWORK_NAME=${NW1_NAME}
  local VLAN_NAME=${NW1_VLAN}
  local PE_CREDS_PASSWORD="${PE_PASSWORD}"
  local PC_CREDS_PASSWORD="${PE_PASSWORD}"
  #local ERACLI_PASSWORD=$(awk '{printf "%s\\n", $0}' ${DIRECTORY}/${CALM_RSA_KEY_FILE})
  local DOWNLOAD_BLUEPRINTS
  local CURL_HTTP_OPTS="--max-time 25 --silent -k --header Content-Type:application/json --header Accept:application/json  --insecure"
  local _loops="0"
  local _maxtries="75"


  echo "Starting Karbon Blueprint Deployment"

  mkdir $DIRECTORY

  # download the blueprint
  DOWNLOAD_BLUEPRINTS=$(curl -L ${BLUEPRINT_URL}${BLUEPRINT} -o ${DIRECTORY}/${BLUEPRINT})
  log "Downloading ${BLUEPRINT} | BLUEPRINT_URL ${BLUEPRINT_URL}|${DOWNLOAD_BLUEPRINTS}"

  # ensure the directory that contains the blueprints to be imported is not empty
  if [[ $(ls -l "$DIRECTORY"/*.json) == *"No such file or directory"* ]]; then
      echo "There are no .json files found in the directory provided."
      exit 0
  fi

  if [ $CALM_PROJECT != 'none' ]; then

      # curl command needed:
      # curl -s -k -X POST https://10.42.7.39:9440/api/nutanix/v3/projects/list -H 'Content-Type: application/json' --user admin:techX2019! -d '{"kind": "project", "filter": "name==default"}' | jq -r '.entities[].metadata.uuid'

      # make API call and store project_uuid
      project_uuid=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST --data '{"kind":"project", "filter":"name==BootcampInfra"}' 'https://localhost:9440/api/nutanix/v3/projects/list' | jq -r '.entities[].metadata.uuid')

      echo "Projet UUID = $project_uuid"

      if [ -z "$project_uuid" ]; then
          # project wasn't found
          # exit at this point as we don't want to assume all blueprints should then hit the 'default' project
          echo "Project $CALM_PROJECT was not found. Please check the name and retry."
          exit 0
      else
          echo "Project $CALM_PROJECT exists..."
      fi
  fi

  # update the user with script progress...

  echo "Starting blueprint updates and then Uploading to Calm..."

  # read the entire JSON file from the directory
  JSONFile="${DIRECTORY}/${BLUEPRINT}"

  echo "Currently updating blueprint $JSONFile..."

  # NOTE: bash doesn't do in place editing so we need to use a temp file and overwrite the old file with new changes for every blueprint
  tmp=$(mktemp)

  # ADD PROJECT , we need to add it into the JSON data
  if [ $CALM_PROJECT != 'none' ]; then
      # add the new atributes to the JSON and overwrite the old JSON file with the new one
      $(jq --arg proj $CALM_PROJECT --arg proj_uuid $project_uuid '.metadata+={"project_reference":{"kind":$proj,"uuid":$proj_uuid}}' $JSONFile >"$tmp" && mv "$tmp" $JSONFile)
  fi

  # REMOVE the "status" and "product_version" keys (if they exist) from the JSON data this is included on export but is invalid on import. (affects all BPs being imported)
  tmp_removal=$(mktemp)
  $(jq 'del(.status) | del(.product_version)' $JSONFile >"$tmp_removal" && mv "$tmp_removal" $JSONFile)

  # GET BP NAME (affects all BPs being imported)
  # if this fails, it's either a corrupt/damaged/edited blueprint JSON file or not a blueprint file at all
  blueprint_name_quotes=$(jq '(.spec.name)' $JSONFile)
  blueprint_name="${blueprint_name_quotes%\"}" # remove the suffix "
  blueprint_name="${blueprint_name#\"}" # will remove the prefix "

  if [ $blueprint_name == 'null' ]; then
      echo "Unprocessable JSON file found. Is this definitely a Nutanix Calm blueprint file?"
      exit 0
  else
      # got the blueprint name means it is probably a valid blueprint file, we can now continue the upload
      echo "Uploading the updated blueprint: $blueprint_name..."

      path_to_file=$JSONFile
      bp_name=$blueprint_name
      project_uuid=$project_uuid

      upload_result=$(curl -s -k --insecure --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST https://localhost:9440/api/nutanix/v3/blueprints/import_file -F file=@$path_to_file -F name=$bp_name -F project_uuid=$project_uuid)

      #if the upload_result var is not empty then let's say it was succcessful
      if [ -z "$upload_result" ]; then
          echo "Upload for $bp_name did not finish."
      else
          echo "Upload for $bp_name finished."
          echo "-----------------------------------------"
          # echo "Result: $upload_result"
      fi
  fi

  echo "Finished uploading ${BLUEPRINT}!"

  #Getting the Blueprint UUID
  KARBON_BLUEPRINT_UUID=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST --data '{"kind":"blueprint","filter": "name==KarbonClusterDeployment"}' 'https://localhost:9440/api/nutanix/v3/blueprints/list' | jq -r '.entities[] | .metadata.uuid' | tr -d \")

  echo "Karbon Blueprint UUID = $KARBON_BLUEPRINT_UUID"

  echo "Update Blueprint and writing to temp file"

  echo "${CALM_PROJECT} network UUID: ${project_uuid}"
  echo "KARBON_BLUEPRINT_UUID=${KARBON_BLUEPRINT_UUID}"

  DOWNLOADED_JSONFile="${BLUEPRINT}-${KARBON_BLUEPRINT_UUID}.json"
  UPDATED_JSONFile="${BLUEPRINT}-${KARBON_BLUEPRINT_UUID}-updated.json"

  # GET The Blueprint so it can be updated
  curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X GET -d '{}' "https://localhost:9440/api/nutanix/v3/blueprints/${KARBON_BLUEPRINT_UUID}" > ${DOWNLOADED_JSONFile}

  cat $DOWNLOADED_JSONFile \
  | jq -c 'del(.status)' \
  | jq -c -r "(.spec.resources.credential_definition_list[0].secret.value = \"$PE_CREDS_PASSWORD\")" \
  | jq -c -r '(.spec.resources.credential_definition_list[0].secret.attrs.is_secret_modified = "true")' \
  | jq -c -r "(.spec.resources.credential_definition_list[1].secret.value = \"$PC_CREDS_PASSWORD\")" \
  | jq -c -r '(.spec.resources.credential_definition_list[1].secret.attrs.is_secret_modified = "true")' \
  > $UPDATED_JSONFile

  echo "Saving Credentials Edits with PUT"

  curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X PUT -d @$UPDATED_JSONFile "https://localhost:9440/api/nutanix/v3/blueprints/${KARBON_BLUEPRINT_UUID}"

  echo "Finished Updating Credentials"

  # GET The Blueprint payload
  curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X GET -d '{}' "https://localhost:9440/api/nutanix/v3/blueprints/${KARBON_BLUEPRINT_UUID}" | jq 'del(.status, .spec.name) | .spec += {"application_name": "KarbonClusterDeployment", "app_profile_reference": {"uuid": .spec.resources.app_profile_list[0].uuid, "kind": "app_profile" }}' > set_blueprint_response_file.json

  # Launch the BLUEPRINT

  log "Sleep 30 seconds so the blueprint can settle in......"
  sleep 30

  log "Launching the Karbon Cluster Blueprint"

  curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST -d @set_blueprint_response_file.json "https://localhost:9440/api/nutanix/v3/blueprints/${KARBON_BLUEPRINT_UUID}/launch"

  log "Finished Launching the Karbon Cluster Deployment Blueprint"

}

###############################################################################################################################################################################
# Routine to upload CICDInfra Calm Blueprint and set variables
###############################################################################################################################################################################

function upload_CICDInfra_calm_blueprint() {
  local DIRECTORY="/home/nutanix/cicdinfra"
  local BLUEPRINT=${CICDInfra_Blueprint}
  local CALM_PROJECT="BootcampInfra"
  local NETWORK_NAME=${NW1_NAME}
  local DOWNLOAD_BLUEPRINTS
  local NETWORK_UUID
  local SERVER_IMAGE="CentOS7.qcow2"
  local SERVER_IMAGE_UUID
  local CURL_HTTP_OPTS="--max-time 25 --silent -k --header Content-Type:application/json --header Accept:application/json  --insecure"
  local _loops="0"
  local _maxtries="75"

  echo "Starting CICDInfra Blueprint Deployment"

  mkdir $DIRECTORY

  NETWORK_UUID=$(curl ${CURL_HTTP_OPTS} --request POST 'https://localhost:9440/api/nutanix/v3/subnets/list' --user ${PRISM_ADMIN}:${PE_PASSWORD} --data '{"kind":"subnet","filter": "name==Primary"}' | jq -r '.entities[] | .metadata.uuid' | tr -d \")

  echo "NETWORK UUID = $NETWORK_UUID"
  echo "-----------------------------------------"

  # download the blueprint
  DOWNLOAD_BLUEPRINTS=$(curl -L ${BLUEPRINT_URL}${BLUEPRINT} -o ${DIRECTORY}/${BLUEPRINT})
  log "Downloading ${BLUEPRINT} | BLUEPRINT_URL ${BLUEPRINT_URL}|${DOWNLOAD_BLUEPRINTS}"

  # ensure the directory that contains the blueprints to be imported is not empty
  if [[ $(ls -l "$DIRECTORY"/*.json) == *"No such file or directory"* ]]; then
      echo "There are no .json files found in the directory provided."
      exit 0
  fi

  if [ $CALM_PROJECT != 'none' ]; then

      # curl command needed:
      # curl -s -k -X POST https://10.42.7.39:9440/api/nutanix/v3/projects/list -H 'Content-Type: application/json' --user admin:techX2019! -d '{"kind": "project", "filter": "name==default"}' | jq -r '.entities[].metadata.uuid'

      # make API call and store project_uuid
      project_uuid=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST --data '{"kind":"project", "filter":"name==BootcampInfra"}' 'https://localhost:9440/api/nutanix/v3/projects/list' | jq -r '.entities[].metadata.uuid')

      echo "Projet UUID = $project_uuid"

      if [ -z "$project_uuid" ]; then
          # project wasn't found
          # exit at this point as we don't want to assume all blueprints should then hit the 'default' project
          echo "Project $CALM_PROJECT was not found. Please check the name and retry."
          exit 0
      else
          echo "Project $CALM_PROJECT exists..."
      fi
  fi

  # update the user with script progress...
  echo "Starting blueprint updates and then Uploading to Calm..."

  JSONFile="${DIRECTORY}/${BLUEPRINT}"

  echo "Currently updating blueprint $JSONFile..."

  # NOTE: bash doesn't do in place editing so we need to use a temp file and overwrite the old file with new changes for every blueprint
  tmp=$(mktemp)

  # ADD PROJECT , we need to add it into the JSON data
  if [ $CALM_PROJECT != 'none' ]; then
      # add the new atributes to the JSON and overwrite the old JSON file with the new one
      $(jq --arg proj $CALM_PROJECT --arg proj_uuid $project_uuid '.metadata+={"project_reference":{"kind":$proj,"uuid":$proj_uuid}}' $JSONFile >"$tmp" && mv "$tmp" $JSONFile)
  fi
  # REMOVE the "status" and "product_version" keys (if they exist) from the JSON data this is included on export but is invalid on import. (affects all BPs being imported)
  tmp_removal=$(mktemp)
  $(jq 'del(.status) | del(.product_version)' $JSONFile >"$tmp_removal" && mv "$tmp_removal" $JSONFile)

  # GET BP NAME (affects all BPs being imported)
  # if this fails, it's either a corrupt/damaged/edited blueprint JSON file or not a blueprint file at all
  blueprint_name_quotes=$(jq '(.spec.name)' $JSONFile)
  blueprint_name="${blueprint_name_quotes%\"}" # remove the suffix "
  blueprint_name="${blueprint_name#\"}" # will remove the prefix "

  if [ $blueprint_name == 'null' ]; then
      echo "Unprocessable JSON file found. Is this definitely a Nutanix Calm blueprint file?"
      exit 0
  else
      # got the blueprint name means it is probably a valid blueprint file, we can now continue the upload
      echo "Uploading the updated blueprint: $blueprint_name..."


      path_to_file=$JSONFile
      bp_name=$blueprint_name
      project_uuid=$project_uuid

      upload_result=$(curl -s -k --insecure --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST -F file=@$path_to_file -F name=$bp_name -F project_uuid=$project_uuid 'https://localhost:9440/api/nutanix/v3/blueprints/import_file')

      #if the upload_result var is not empty then let's say it was succcessful
      if [ -z "$upload_result" ]; then
          echo "Upload for $bp_name did not finish."
      else
          echo "Upload for $bp_name finished."
          echo "-----------------------------------------"
          # echo "Result: $upload_result"
      fi
  fi

  echo "Finished uploading ${BLUEPRINT}!"

  #Getting the Blueprint UUID
  CICDInfra_BLUEPRINT_UUID=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X POST --data '{"kind":"blueprint","filter": "name==CICD_Infra"}' 'https://localhost:9440/api/nutanix/v3/blueprints/list' | jq -r '.entities[] | .metadata.uuid' | tr -d \")

  echo "CICD Blueprint UUID = $CICDInfra_BLUEPRINT_UUID"

  echo "Update Blueprint and writing to temp file"

  echo "${CALM_PROJECT} network UUID: ${project_uuid}"
  echo "NETWORK_UUID=${NETWORK_UUID}"

  DOWNLOADED_JSONFile="${BLUEPRINT}-${CICDInfra_BLUEPRINT_UUID}.json"
  UPDATED_JSONFile="${BLUEPRINT}-${CICDInfra_BLUEPRINT_UUID}-updated.json"

  # GET The Blueprint so it can be updated
  curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X GET -d '{}' "https://localhost:9440/api/nutanix/v3/blueprints/${CICDInfra_BLUEPRINT_UUID}" > ${DOWNLOADED_JSONFile}

  cat $DOWNLOADED_JSONFile \
  | jq -c 'del(.status)' \
  | jq -c -r "(.spec.resources.substrate_definition_list[0].create_spec.resources.nic_list[].subnet_reference.name = \"$NETWORK_NAME\")" \
  | jq -c -r "(.spec.resources.substrate_definition_list[0].create_spec.resources.nic_list[].subnet_reference.uuid = \"$NETWORK_UUID\")" \
  | jq -c -r "(.spec.resources.substrate_definition_list[1].create_spec.resources.nic_list[].subnet_reference.name = \"$NETWORK_NAME\")" \
  | jq -c -r "(.spec.resources.substrate_definition_list[1].create_spec.resources.nic_list[].subnet_reference.uuid = \"$NETWORK_UUID\")" \
  | jq -c -r "(.spec.resources.substrate_definition_list[2].create_spec.resources.nic_list[].subnet_reference.name = \"$NETWORK_NAME\")" \
  | jq -c -r "(.spec.resources.substrate_definition_list[2].create_spec.resources.nic_list[].subnet_reference.uuid = \"$NETWORK_UUID\")" \
  | jq -c -r "(.spec.resources.substrate_definition_list[3].create_spec.resources.nic_list[].subnet_reference.name = \"$NETWORK_NAME\")" \
  | jq -c -r "(.spec.resources.substrate_definition_list[3].create_spec.resources.nic_list[].subnet_reference.uuid = \"$NETWORK_UUID\")" \
  | jq -c -r "(.spec.resources.credential_definition_list[0].secret.value=\"-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEAii7qFDhVadLx5lULAG/ooCUTA/ATSmXbArs+GdHxbUWd/bNG\nZCXnaQ2L1mSVVGDxfTbSaTJ3En3tVlMtD2RjZPdhqWESCaoj2kXLYSiNDS9qz3SK\n6h822je/f9O9CzCTrw2XGhnDVwmNraUvO5wmQObCDthTXc72PcBOd6oa4ENsnuY9\nHtiETg29TZXgCYPFXipLBHSZYkBmGgccAeY9dq5ywiywBJLuoSovXkkRJk3cd7Gy\nhCRIwYzqfdgSmiAMYgJLrz/UuLxatPqXts2D8v1xqR9EPNZNzgd4QHK4of1lqsNR\nuz2SxkwqLcXSw0mGcAL8mIwVpzhPzwmENC5OrwIBJQKCAQB++q2WCkCmbtByyrAp\n6ktiukjTL6MGGGhjX/PgYA5IvINX1SvtU0NZnb7FAntiSz7GFrODQyFPQ0jL3bq0\nMrwzRDA6x+cPzMb/7RvBEIGdadfFjbAVaMqfAsul5SpBokKFLxU6lDb2CMdhS67c\n1K2Hv0qKLpHL0vAdEZQ2nFAMWETvVMzl0o1dQmyGzA0GTY8VYdCRsUbwNgvFMvBj\n8T/svzjpASDifa7IXlGaLrXfCH584zt7y+qjJ05O1G0NFslQ9n2wi7F93N8rHxgl\nJDE4OhfyaDyLL1UdBlBpjYPSUbX7D5NExLggWEVFEwx4JRaK6+aDdFDKbSBIidHf\nh45NAoGBANjANRKLBtcxmW4foK5ILTuFkOaowqj+2AIgT1ezCVpErHDFg0bkuvDk\nQVdsAJRX5//luSO30dI0OWWGjgmIUXD7iej0sjAPJjRAv8ai+MYyaLfkdqv1Oj5c\noDC3KjmSdXTuWSYNvarsW+Uf2v7zlZlWesTnpV6gkZH3tX86iuiZAoGBAKM0mKX0\nEjFkJH65Ym7gIED2CUyuFqq4WsCUD2RakpYZyIBKZGr8MRni3I4z6Hqm+rxVW6Dj\nuFGQe5GhgPvO23UG1Y6nm0VkYgZq81TraZc/oMzignSC95w7OsLaLn6qp32Fje1M\nEz2Yn0T3dDcu1twY8OoDuvWx5LFMJ3NoRJaHAoGBAJ4rZP+xj17DVElxBo0EPK7k\n7TKygDYhwDjnJSRSN0HfFg0agmQqXucjGuzEbyAkeN1Um9vLU+xrTHqEyIN/Jqxk\nhztKxzfTtBhK7M84p7M5iq+0jfMau8ykdOVHZAB/odHeXLrnbrr/gVQsAKw1NdDC\nkPCNXP/c9JrzB+c4juEVAoGBAJGPxmp/vTL4c5OebIxnCAKWP6VBUnyWliFhdYME\nrECvNkjoZ2ZWjKhijVw8Il+OAjlFNgwJXzP9Z0qJIAMuHa2QeUfhmFKlo4ku9LOF\n2rdUbNJpKD5m+IRsLX1az4W6zLwPVRHp56WjzFJEfGiRjzMBfOxkMSBSjbLjDm3Z\niUf7AoGBALjvtjapDwlEa5/CFvzOVGFq4L/OJTBEBGx/SA4HUc3TFTtlY2hvTDPZ\ndQr/JBzLBUjCOBVuUuH3uW7hGhW+DnlzrfbfJATaRR8Ht6VU651T+Gbrr8EqNpCP\ngmznERCNf9Kaxl/hlyV5dZBe/2LIK+/jLGNu9EJLoraaCBFshJKF\n-----END RSA PRIVATE KEY-----\n\")" \
  | jq -c -r '(.spec.resources.credential_definition_list[0].secret.attrs.is_secret_modified = "true")' \
  > $UPDATED_JSONFile

  echo "Saving Credentials Edits with PUT"

  curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${PE_PASSWORD} -X PUT -d @$UPDATED_JSONFile "https://localhost:9440/api/nutanix/v3/blueprints/${CICDInfra_BLUEPRINT_UUID}"

  echo "Finished Updating Credentials"

  echo "Finished CICDInfra Blueprint Deployment"

}