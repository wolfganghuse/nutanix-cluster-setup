#!/usr/bin/env bash

# Example use from a Nutanix CVM:
## curl --remote-name --location https://raw.githubusercontent.com/wolfganghuse/nutanix-cluster-setup/master/bootstrap.sh && sh ${_##*/}

ORGANIZATION=wolfganghuse
REPOSITORY=nutanix-cluster-setup
BRANCH=master

BASE_URL=https://github.com/${ORGANIZATION}/${REPOSITORY}
ARCHIVE=${BASE_URL}/archive/${BRANCH}.zip

. /etc/profile.d/nutanix_env.sh || _ERROR=1

if (( ${_ERROR} == 1 )); then
  echo "Error ${_ERROR}: This script should be run on a Nutanix CVM!"
  #echo RESTORE:

#########################################################################
### Added to verify user is Nutanix 7/22/2019 from mlavi version of file.
#########################################################################

  exit ${_ERROR}
elif [[ $(whoami) != 'nutanix' ]]; then
  _ERROR=50
  echo "PBC-50: This guardrail can be relaxed with proper testing for the future."
  echo "Error ${_ERROR}: This script should be run as user nutanix!"
  exit ${_ERROR}
fi

CLUSTER_NAME=' '
CLUSTER_NAME+=$(ncli cluster get-params | grep 'Cluster Name' \
              | awk -F: '{print $2}' | tr -d '[:space:]')


echo -e "\nNo cache: retrieving ${ARCHIVE} ..."
curl --remote-name --location ${ARCHIVE} \
&& echo "Success: ${ARCHIVE##*/}" \
&& unzip ${ARCHIVE##*/}

pushd ${REPOSITORY}-${BRANCH}/ \
  && chmod -R u+x *.sh


echo -e "\nStarting stage_cluster.sh for ${EMAIL} with ${PRISM_ADMIN}:passwordNotShown@${PE_HOST} ...\n"


EMAIL=${EMAIL} \
PE_HOST=${PE_HOST} \
PRISM_ADMIN=${PRISM_ADMIN} \
PE_PASSWORD=${PE_PASSWORD} \
MY_WORKSHOP="ws1"
./stage_cluster.sh -f - ${MY_WORKSHOP} # \
#  && popd || exit

echo -e "\n    DONE: ${0} ran for ${SECONDS} seconds."
cat <<EOM
Optional: Please consider running ${0} clean.

Watch progress with:
          tail -f *.log &
or login to PE to see tasks in flight and eventual PC registration:
          https://${PE_HOST}:9440/
EOM