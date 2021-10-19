ncli=/home/nutanix/prism/cli/ncli
acli=/usr/local/nutanix/bin/acli

CLUSTER_NAME=NTNX-Demo
PE_HOST=172.23.1.121
PC_HOST=172.23.1.123
DATA_SERVICE_IP=172.23.1.122
timezone=Europe/Berlin
STORAGE_POOL=sp1
STORAGE_DEFAULT=Default
STORAGE_IMAGES=Images
centos_image=CentOS7-Install
centos_annotation="CentOS7-Installation-ISO"
centos_source=http://iso-store.objects-clu1.ntnx.test/CentOS7-2009.qcow2
SSH_PUBKEY="${HOME}/.ssh/id_rsa.pub"
OCTET=(${PE_HOST//./ }) # zero index

NW1_NAME='Primary'
NW1_VLAN=0
NW1_SUBNET="172.23.0.1/16"
NW1_GATEWAY="172.23.0.1"
NW1_DHCP_START="172.23.108.140"
NW1_DHCP_END="172.23.108.140"
IPV4_PREFIX='172.23.108'
SUBNET_MASK="255.255.0.0"

AUTH_SERVER='AutoDC' # default; TODO:180 refactor AUTH_SERVER choice to input file
AUTH_HOST='172.23.108.139'
LDAP_PORT=389
AUTH_FQDN='ntnxlab.local'
AUTH_DOMAIN='NTNXLAB'
AUTH_ADMIN_USER='administrator@'${AUTH_FQDN}
AUTH_ADMIN_PASS='nutanix/4u'
AUTH_ADMIN_GROUP='SSP Admins'


centos7_vm_name=CentOS7-VM
centos7_vm_disk_size=20G
PRISM_ADMIN=admin
PE_PASSWORD=nx2Tech100!
PE_DEFAULTPW=Nutanix/4u
NTNX_INIT_PASSWORD='nutanix/4u'
PC_VERSION='pc.2021.9'
PC_STABLE_VERSION='pc.2021.9'
PC_LAUNCH='setup-pc.sh'
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


DNS_SERVERS='172.23.0.23'
NTP_SERVERS='0.us.pool.ntp.org,1.us.pool.ntp.org,2.us.pool.ntp.org,3.us.pool.ntp.org'
OS_NAME='"centos"'
JQ_REPOS=(\
        'https://github.com/stedolan/jq/releases/download/jq-1.5/jq-linux64' \
)
AUTODC_REPOS=(\
    'http://iso-store.objects-clu1.ntnx.test/autodc-2.0.qcow2' \
)
SSHPASS_REPOS=(\
       'http://mirror.centos.org/centos/7/extras/x86_64/Packages/sshpass-1.06-2.el7.x86_64.rpm' \
    )
PC_STABLE_METAURL='http://iso-store.objects-clu1.ntnx.test/pc.2021.9-metadata.json'
PC_STABLE_URL='http://iso-store.objects-clu1.ntnx.test/pc.2021.9.tar'

