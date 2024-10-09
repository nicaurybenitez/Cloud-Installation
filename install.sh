#!/bin/bash
if [ "$EUID" -ne 0 ]
  then echo "
  ############################################################################# 
  ##         This script must be run as root or with sudo command            ##   
  ##  before running the script switch to root user using <su> or <sudo su>  ##
  #############################################################################
  "
  sleep 15
  exit
fi

UBUNTU_VERSION=$(lsb_release -rs)
REQUIRED_VERSION1="24."
REQUIRED_VERSION2="22."

if (( $(echo "$UBUNTU_VERSION < $REQUIRED_VERSION1" | bc -l) )) && [[ "$UBUNTU_VERSION" != $REQUIRED_VERSION2* ]]
then
    echo "
    ############################################################################# 
    ##         This script requires Ubuntu version 22.04 or 20.xx             ##   
    #############################################################################
    "
    sleep 15
    exit
fi

echo -e "\033[1;34m"  # Cambia el color a azul brillante para mayor visibilidad

echo "
 ██████╗██╗      ██████╗ ██╗   ██╗██████╗      ██████╗ ███╗   ██╗██████╗ ██████╗ ███████╗███╗   ███╗██╗███████╗███████╗
██╔════╝██║     ██╔═══██╗██║   ██║██╔══██╗    ██╔═══██╗████╗  ██║██╔══██╗██╔══██╗██╔════╝████╗ ████║██║██╔════╝██╔════╝
██║     ██║     ██║   ██║██║   ██║██║  ██║    ██║   ██║██╔██╗ ██║██████╔╝██████╔╝█████╗  ██╔████╔██║██║███████╗█████╗  
██║     ██║     ██║   ██║██║   ██║██║  ██║    ██║   ██║██║╚██╗██║██╔═══╝ ██╔══██╗██╔══╝  ██║╚██╔╝██║██║╚════██║██╔══╝  
╚██████╗███████╗╚██████╔╝╚██████╔╝██████╔╝    ╚██████╔╝██║ ╚████║██║     ██║  ██║███████╗██║ ╚═╝ ██║██║███████║███████╗
 ╚═════╝╚══════╝ ╚═════╝  ╚═════╝ ╚═════╝      ╚═════╝ ╚═╝  ╚═══╝╚═╝     ╚═╝  ╚═╝╚══════╝╚═╝     ╚═╝╚═╝╚══════╝╚══════╝
"

echo -e "\033[0m"  # Restablece el color
###################################################################################
####           This script is written for Ubuntu 24.04                        ####
####           This script will install Cloudstack 4.19                       ####
###################################################################################


apt update && apt upgrade -y

#######################################
#installing openJDK
#######################################
apt install openjdk-11-jdk -y

#######################################

#######################################
# installing prerequisites for cloudstack
#######################################
apt-get install -y openntpd openssh-server sudo vim htop tar intel-microcode bridge-utils mysql-server


GATEWAY=$(ip r | awk '/default/ {print $3}')
IP=$(ip r | awk '/src/ {print $9; exit}')
ADAPTER=$(ip link | awk -F: '$0 !~ "lo|vir|wl|^[^0-9]"{print $2;getline}')

HOSTS_CONTENT="127.0.0.1\tlocalhost\n$IP\tcloud.ngi.local\tcloud"
apt install bridge-utils


# Check if the bridge already exists
if ! brctl show | grep -q 'br0'; then
    brctl addbr br0
fi

# Check if the interface is already added to the bridge
if ! brctl show br0 | grep -q "$ADAPTER"; then
    brctl addif br0 $ADAPTER
fi

NETPLAN_CONTENT="network:
    version: 2
    renderer: networkd
    ethernets:
        $ADAPTER:
            dhcp4: no
            dhcp6: no
    bridges:
        br0:
            interfaces: [$ADAPTER]
            dhcp4: no
            dhcp6: no
            addresses: [$IP/24]
            routes:
              - to: default
                via: $GATEWAY
            nameservers:
                addresses: [8.8.8.8, 8.8.4.4]"

# Encontrar el archivo de configuración de netplan
NETPLAN_FILE=$(find /etc/netplan -name "*.yaml" | head -n 1)

if [ -z "$NETPLAN_FILE" ]; then
    echo "No se encontró archivo de configuración de netplan. Creando uno nuevo."
    NETPLAN_FILE="/etc/netplan/50-cloud-init.yaml"
fi

# Verificar la gateway actual
CURRENT_GATEWAY=$(grep -oP '(?<=gateway4: )[^ ]*' $NETPLAN_FILE 2>/dev/null || echo "")

if [ "$CURRENT_GATEWAY" != "$GATEWAY" ] || [ -z "$CURRENT_GATEWAY" ]
then
    echo "Actualizando configuración de netplan..."
    cp $NETPLAN_FILE ${NETPLAN_FILE}.bak
    echo "$NETPLAN_CONTENT" | sudo tee $NETPLAN_FILE
else
    echo "La configuración de netplan ya está actualizada."
fi

netplan apply
netplan apply
systemctl restart NetworkManager
hostnamectl set-hostname cloud.ngi.local


apt-get install -y openntpd openssh-server sudo vim htop tar intel-microcode bridge-utils mysql-server

UBUNTU_VERSION=$(lsb_release -rs)

if [[ "$UBUNTU_VERSION" == "24."* ]]
then
    echo deb [arch=amd64] http://download.cloudstack.org/ubuntu noble 4.19 > /etc/apt/sources.list.d/cloudstack.list
elif [[ "$UBUNTU_VERSION" == "22."* ]]
then
    echo deb [arch=amd64] http://download.cloudstack.org/ubuntu jammy 4.19 > /etc/apt/sources.list.d/cloudstack.list
else
    echo "Unsupported Ubuntu version. This script supports Ubuntu 22.04 and 24.04 only."
    exit 1
fi

wget -O - http://download.cloudstack.org/release.asc|gpg --dearmor > cloudstack-archive-keyring.gpg


mv cloudstack-archive-keyring.gpg /etc/apt/trusted.gpg.d/


apt update && apt upgrade -y
apt-get install -y cloudstack-management cloudstack-usage



echo -e "\nserver_id = 1\nsql-mode=\"STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION,ERROR_FOR_DIVISION_BY_ZERO,NO_ZERO_DATE,NO_ZERO_IN_DATE,NO_ENGINE_SUBSTITUTION\"\ninnodb_rollback_on_timeout=1\ninnodb_lock_wait_timeout=600\nmax_connections=1000\nlog-bin=mysql-bin\nbinlog-format = 'ROW'" | sudo tee -a /etc/mysql/mysql.conf.d/mysqld.cnf


echo -e "[mysqld]" | sudo tee /etc/mysql/mysql.conf.d/cloudstack.cnf


systemctl restart mysql

echo "
###################################################################################
# In the next command if it will ask for password just press enter and do nothing #
###################################################################################
"

mysql -u root -p -e "
SELECT user,authentication_string,plugin,host FROM mysql.user;
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY 'dewansnehra';
use mysql;
UPDATE user SET plugin='mysql_native_password' WHERE User='root';
flush privileges;   
"
apt-get install -y cloudstack-management cloudstack-usage
cloudstack-setup-databases devil:devil@localhost --deploy-as=root:dewansnehra

cloudstack-setup-management


ufw allow mysql
mkdir -p /export/primary
mkdir -p /export/secondary
echo "/export *(rw,async,no_root_squash,no_subtree_check)" | sudo tee -a /etc/exports
apt install nfs-kernel-server
service nfs-kernel-server restart
mkdir -p /mnt/primary
mkdir -p /mnt/secondary
mount -t nfs localhost:/export/primary /mnt/primary
mount -t nfs localhost:/export/secondary /mnt/secondary


echo "
###################################################################################
####           Thank you for using this script.                                ####
###################################################################################
"

width=$(tput cols)
progress_width=$((width - 20))
sleep_duration=$(echo "60 / $progress_width" | bc -l)
echo -n "Progress: ["
for i in $(seq 1 $progress_width)
do
    sleep $sleep_duration
    echo -n "#"
done
echo "]"
echo "
###################################################################################
####           Installation done. You can go to http://localhost:8080          ####
####           to access the pannel.                                           ####
####           Username : admin                                                ####
####           Password : password                                             ####
###################################################################################
"
