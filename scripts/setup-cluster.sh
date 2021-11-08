ncli=/home/nutanix/prism/cli/ncli
cvm_ips="10.20.128.31,10.20.128.32,10.20.128.33"
dns_ip="9.9.9.9,1.1.1.1"
PE_HOST="10.20.128.41"
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
