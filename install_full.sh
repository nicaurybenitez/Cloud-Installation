#!/bin/bash

# Verificar si se está ejecutando como root
if [ "$(id -u)" -ne 0 ]; then
  echo "Este script debe ejecutarse como root o con el comando sudo."
  exit 1
fi

# Verificar la versión de Ubuntu
UBUNTU_VERSION=$(lsb_release -rs)
MAJOR_VERSION=$(echo $UBUNTU_VERSION | cut -d. -f1)
if [ "$MAJOR_VERSION" != "22" ] && [ "$MAJOR_VERSION" != "24" ]; then
    echo "Versión de Ubuntu no soportada. Este script soporta Ubuntu 22.04 y 24.04 solamente."
    exit 1
fi

# Función para mostrar el banner
show_banner() {
    cat << EOF
 ██████╗██╗      ██████╗ ██╗   ██╗██████╗      ██████╗ ███╗   ██╗██████╗ ██████╗ ███████╗███╗   ███╗██╗███████╗███████╗
██╔════╝██║     ██╔═══██╗██║   ██║██╔══██╗    ██╔═══██╗████╗  ██║██╔══██╗██╔══██╗██╔════╝████╗ ████║██║██╔════╝██╔════╝
██║     ██║     ██║   ██║██║   ██║██║  ██║    ██║   ██║██╔██╗ ██║██████╔╝██████╔╝█████╗  ██╔████╔██║██║███████╗█████╗  
██║     ██║     ██║   ██║██║   ██║██║  ██║    ██║   ██║██║╚██╗██║██╔═══╝ ██╔══██╗██╔══╝  ██║╚██╔╝██║██║╚════██║██╔══╝  
╚██████╗███████╗╚██████╔╝╚██████╔╝██████╔╝    ╚██████╔╝██║ ╚████║██║     ██║  ██║███████╗██║ ╚═╝ ██║██║███████║███████╗
 ╚═════╝╚══════╝ ╚═════╝  ╚═════╝ ╚═════╝      ╚═════╝ ╚═╝  ╚═══╝╚═╝     ╚═╝  ╚═╝╚══════╝╚═╝     ╚═╝╚═╝╚══════╝╚══════╝
EOF
}

show_banner

echo "###################################################################################"
echo "####           This script is written for Ubuntu 22.04 and 24.04               ####"
echo "####           This script will install Cloudstack 4.19                        ####"
echo "###################################################################################"

# Función para seleccionar el tipo de instalación
select_installation_type() {
    echo "Por favor, seleccione el tipo de instalación:"
    echo "1) Solo host"
    echo "2) Host + Management"
    read -p "Ingrese su elección (1 o 2): " choice
    case $choice in
        1) 
            echo "Ha seleccionado instalar solo el host."
            INSTALL_TYPE="host"
            ;;
        2) 
            echo "Ha seleccionado instalar host + management."
            INSTALL_TYPE="full"
            ;;
        *) 
            echo "Opción no válida. Saliendo."
            exit 1
            ;;
    esac
}

# Llamar a la función de selección
select_installation_type

# Actualizar el sistema
apt update && apt upgrade -y

# Instalar OpenJDK y prerrequisitos
apt install -y openjdk-11-jdk openntpd openssh-server uuid sudo vim htop tar intel-microcode bridge-utils

# Instalar MySQL solo si es instalación completa
if [ "$INSTALL_TYPE" = "full" ]; then
    apt install -y mysql-server
fi

# Función para obtener la IP principal y la interfaz
get_network_info() {
    INTERFACE=$(ip route | awk '/default/ {print $5; exit}')
    IP=$(ip -4 addr show $INTERFACE | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
    GATEWAY=$(ip route | awk '/default/ {print $3}')
    if [ -z "$INTERFACE" ] || [ -z "$IP" ] || [ -z "$GATEWAY" ]; then
        echo "Error al obtener la información de red." >&2
        return 1
    fi
    echo "$INTERFACE $IP $GATEWAY"
}

# Configurar red
NETWORK_INFO=$(get_network_info)
if [ $? -ne 0 ]; then
    echo "Error al obtener la información de red. Saliendo del script."
    exit 1
fi

INTERFACE=$(echo $NETWORK_INFO | cut -d' ' -f1)
IP=$(echo $NETWORK_INFO | cut -d' ' -f2)
GATEWAY=$(echo $NETWORK_INFO | cut -d' ' -f3)

# Eliminar configuraciones de red existentes
rm -f /etc/netplan/*.yaml

# Crear el contenido de netplan
cat > /etc/netplan/01-netcfg.yaml << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INTERFACE:
      dhcp4: no
  bridges:
    cloudbr0:
      interfaces: [$INTERFACE]
      addresses: [$IP/24]
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses: [8.8.8.8, 8.8.4.4]
      parameters:
        stp: false
        forward-delay: 0
EOF

# Aplicar la configuración
netplan generate
netplan apply

# Verificar la conectividad
if ! ping -c 4 8.8.8.8 > /dev/null 2>&1; then
    echo "Error: No se pudo establecer conexión a Internet."
    exit 1
fi

echo "La configuración de red se ha aplicado correctamente y hay conexión a Internet."

# Configurar hostname
hostnamectl set-hostname cloud.ngi.local

# Agregar repositorio de CloudStack
if [ "$MAJOR_VERSION" = "24" ]; then
    echo "deb [arch=amd64] http://download.cloudstack.org/ubuntu noble 4.19" > /etc/apt/sources.list.d/cloudstack.list
elif [ "$MAJOR_VERSION" = "22" ]; then
    echo "deb [arch=amd64] http://download.cloudstack.org/ubuntu jammy 4.19" > /etc/apt/sources.list.d/cloudstack.list
fi

wget -O - http://download.cloudstack.org/release.asc | gpg --dearmor > /etc/apt/trusted.gpg.d/cloudstack-archive-keyring.gpg

# Actualizar e instalar CloudStack
apt update && apt upgrade -y

if [ "$INSTALL_TYPE" = "full" ]; then
    apt-get install -y cloudstack-management cloudstack-usage

    # Configurar MySQL
    cat >> /etc/mysql/mysql.conf.d/mysqld.cnf << EOF

server_id = 1
sql-mode="STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION,ERROR_FOR_DIVISION_BY_ZERO,NO_ZERO_DATE,NO_ZERO_IN_DATE,NO_ENGINE_SUBSTITUTION"
innodb_rollback_on_timeout=1
innodb_lock_wait_timeout=600
max_connections=1000
log-bin=mysql-bin
binlog-format = 'ROW'
EOF

    echo "[mysqld]" > /etc/mysql/mysql.conf.d/cloudstack.cnf

    systemctl restart mysql

    # Configurar MySQL para CloudStack
    mysql -u root << EOF
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '1qazxsw2';
FLUSH PRIVILEGES;
EOF

    # Configurar CloudStack
    cloudstack-setup-databases ezzy:ezzy@localhost --deploy-as=root:1qazxsw2
    cloudstack-setup-management
fi

# Configurar firewall
ufw allow mysql
ufw allow proto tcp from any to any port 22
ufw allow proto tcp from any to any port 1798
ufw allow proto tcp from any to any port 16509
ufw allow proto tcp from any to any port 16514
ufw allow proto tcp from any to any port 5900:6100
ufw allow proto tcp from any to any port 49152:49216

# Habilitar ssh
# Configurar acceso SSH para root
echo "Configurando acceso SSH para root..."
sed -i 's/^#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config

# Establecer contraseña para root
echo "Por favor, establece una contraseña para el usuario root:"
passwd root

# Reiniciar el servicio SSH
if systemctl is-active --quiet ssh; then
    echo "Reiniciando servicio ssh..."
    systemctl restart ssh
elif systemctl is-active --quiet sshd; then
    echo "Reiniciando servicio sshd..."
    systemctl restart sshd
else
    echo "No se pudo encontrar el servicio SSH. Por favor, reinicia el servicio manualmente."
fi

# Configurar NFS (solo para instalación completa)
if [ "$INSTALL_TYPE" = "full" ]; then
    mkdir -p /export/primary /export/secondary
    echo "/export *(rw,async,no_root_squash,no_subtree_check)" >> /etc/exports
    apt install -y nfs-kernel-server
    systemctl restart nfs-kernel-server
    mkdir -p /mnt/primary /mnt/secondary
    mount -t nfs localhost:/export/primary /mnt/primary
    mount -t nfs localhost:/export/secondary /mnt/secondary
fi

# Instalar KVM y agente de CloudStack
apt install -y qemu-kvm cloudstack-agent

# Configurar KVM
sed -i -e 's/\#vnc_listen.*$/vnc_listen = "0.0.0.0"/g' /etc/libvirt/qemu.conf

# Configurar libvirtd
echo 'listen_tls=0' >> /etc/libvirt/libvirtd.conf
echo 'listen_tcp=1' >> /etc/libvirt/libvirtd.conf
echo 'tcp_port = "16509"' >> /etc/libvirt/libvirtd.conf
echo 'mdns_adv = 0' >> /etc/libvirt/libvirtd.conf
echo 'auth_tcp = "none"' >> /etc/libvirt/libvirtd.conf

# Generar y configurar UUID único para libvirt
apt-get install -y uuid
UUID=$(uuid)
echo "host_uuid = \"$UUID\"" >> /etc/libvirt/libvirtd.conf

# Configurar libvirtd para iniciar en modo de escucha
if [ "$MAJOR_VERSION" = "22" ]; then
    echo LIBVIRTD_ARGS=\"--listen\" >> /etc/default/libvirtd
else
    sed -i -e 's/.*libvirtd_opts.*/libvirtd_opts="-l"/' /etc/default/libvirtd
fi

# Reiniciar libvirtd
systemctl restart libvirtd

echo "
###################################################################################
####           Thank you for using this script.                                ####
###################################################################################
"

if [ "$INSTALL_TYPE" = "full" ]; then
    echo "
###################################################################################
####           Installation done. You can go to http://localhost:8080          ####
####           to access the panel.                                            ####
####           Username : admin                                                ####
####           Password : password                                             ####
###################################################################################
"
else
    echo "
###################################################################################
####           Host installation completed.                                    ####
####           You can now add this host to your CloudStack management server. ####
###################################################################################
"
fi