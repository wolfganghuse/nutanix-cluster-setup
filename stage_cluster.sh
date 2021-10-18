#!/usr/bin/env bash
# use bash -x to debug command substitution and evaluation instead of echo.
DEBUG=

# Source Workshop common routines + global variables
. scripts/lib.common.sh
. scripts/global.vars.sh


function stage_clusters() {
  local      _cluster
  local    _container
  local _dependency
  local       _fields
  local    _libraries='global.vars.sh lib.common.sh '
  local    _pe_launch # will be transferred and executed on PE
  local    _pc_launch # will be transferred and executed on PC
  local       _sshkey=${SSH_PUBKEY}
  
 
  export PC_VERSION="${PC_STABLE_VERSION}"

  _libraries+='lib.pe.sh lib.pc.sh'
  _pe_launch='basic_setup.sh'
  _pc_launch=${_pe_launch}
  
  dependencies 'install' 'sshpass'

  # Send configuration scripts to remote clusters and execute Prism Element script
  echo "Login to see tasks in flight via https://${PRISM_ADMIN}:${PE_PASSWORD}@${PE_HOST}:9440"
  pe_configuration_args "${_pc_launch}"

  pushd scripts || true
  eval "${PE_CONFIGURATION} ./${_pe_launch} 'PE'" #>> ${HOME}/${_pe_launch%%.sh}.log 2>&1 &
  unset PE_CONFIGURATION
  popd || true
  finish
  exit
}

function pe_configuration_args() {
  local _pc_launch="${1}"

  PE_CONFIGURATION="EMAIL=${EMAIL} PRISM_ADMIN=${PRISM_ADMIN} PE_PASSWORD=${PE_PASSWORD} PE_HOST=${PE_HOST} PC_LAUNCH=${_pc_launch} PC_VERSION=${PC_VERSION}"
}

function validate_clusters() {
  local _cluster
  local  _fields

  for _cluster in $(cat ${CLUSTER_LIST} | grep -v ^\#)
  do
    set -f
    # shellcheck disable=2206
        _fields=(${_cluster//|/ })
        PE_HOST=${_fields[0]}
    PE_PASSWORD=${_fields[1]}

    prism_check 'PE'
    if (( $? == 0 )) ; then
      log "Success: execute PE API on ${PE_HOST}"
    else
      log "Failure: cannot validate PE API on ${PE_HOST}"
    fi
  done
}


#__main__

echo Start Stage
stage_clusters
