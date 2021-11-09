
CLUSTER_NAME=NTNX-Prod
PE_HOST=10.20.128.41
PC_HOST=10.20.128.43
DATA_SERVICE_IP=10.20.128.42
STORAGE_POOL=sp1
STORAGE_DEFAULT=Default
STORAGE_IMAGES=Images
SSH_PUBKEY="${HOME}/.ssh/id_rsa.pub"
OCTET=(${PE_HOST//./ }) # zero index

NW1_NAME='Primary'
NW1_VLAN=0
NW1_SUBNET="10.20.128.1/24"
NW1_GATEWAY="10.20.128.1"
NW1_DHCP_START="10.20.128.101"
NW1_DHCP_END="10.20.128.199"
IPV4_PREFIX='10.20.128'
SUBNET_MASK="255.255.255.0"

AUTH_SERVER='AutoDC' # default; TODO:180 refactor AUTH_SERVER choice to input file
AUTH_HOST='10.20.128.44'
LDAP_PORT=389
AUTH_FQDN='ntnxlab.local'
AUTH_DOMAIN='NTNXLAB'
AUTH_ADMIN_USER='administrator@'${AUTH_FQDN}
AUTH_ADMIN_PASS='nutanix/4u'
AUTH_ADMIN_GROUP='SSP Admins'


PRISM_ADMIN=admin
PE_PASSWORD=nx2Tech100!
PE_DEFAULTPW=Nutanix/4u
NTNX_INIT_PASSWORD='nutanix/4u'
PC_VERSION='pc.2021.9'
PC_STABLE_VERSION='pc.2021.9'
CURL_HTTP_OPTS=' --max-time 25 --silent --header Content-Type:application/json --header Accept:application/json  --insecure '
EMAIL=wolfgang@nutanix.com
SMTP_SERVER_ADDRESS=1.1.1.1
SMTP_SERVER_FROM=wolfgang@nutanix.com
SMTP_SERVER_PORT=25
ATTEMPTS=40
SLEEP=60
CURL_OPTS='--insecure --silent --show-error' # --verbose'
CURL_POST_OPTS="${CURL_OPTS} --max-time 5 --header Content-Type:application/json --header Accept:application/json --output /dev/null"
CURL_HTTP_OPTS="${CURL_POST_OPTS} --write-out %{http_code}"
SSH_OPTS='-o StrictHostKeyChecking=no -o GlobalKnownHostsFile=/dev/null -o UserKnownHostsFile=/dev/null'
SSH_OPTS+=' -q' # -v'


DNS_SERVERS='10.20.128.44'
NTP_SERVERS='0.us.pool.ntp.org,1.us.pool.ntp.org,2.us.pool.ntp.org,3.us.pool.ntp.org'
OS_NAME='"centos"'
JQ_REPOS=(\
        'http://10.20.128.27/isostore/jq-linux64' \
)
AUTODC_REPOS=(\
    'http://10.20.128.27/isostore/autodc-2.0.qcow2' \
)
SSHPASS_REPOS=(\
       'http://10.20.128.27/isostore/sshpass-1.06-2.el7.x86_64.rpm' \
    )
PC_STABLE_METAURL='http://10.20.128.27/isostore/generated-pc.2021.9-metadata.json'
PC_STABLE_URL='http://10.20.128.27/isostore/pc.2021.9.tar'

