#!/bin/bash

while getopts i:n:s:t: flag
do
    case "${flag}" in
        n) nodetype=${OPTARG};;
        i) k3s_interface=${OPTARG};;
        s) k3s_server_url=${OPTARG};;
        t) k3s_node_token=${OPTARG};;
    esac
done

if [[ -z "$nodetype" ]] ; then
    echo "you must specify a nodetype of server or agent with the -n flag"
    exit 1
elif [[ -z "$k3s_interface" ]] ; then
    echo "you must specify a network interface with the -i flag"
    exit 1
fi

artifact_dir="/opt/artifacts"

systemctl start iptables
systemctl enable iptables
iptables --flush
service iptables save

configure_os() {
    setenforce Permissive
    sed -i s/^SELINUX=.*$/SELINUX=permissive/ /etc/selinux/config
    cat << EOF > /etc/sysctl.d/k3s.conf
  net.ipv4.ip_local_port_range = 15000 61000
  fs.file-max = 12000500
  fs.nr_open = 20000500
  net.ipv4.tcp_mem = 10000000 10000000 10000000
  net.core.rmem_max=8388608
  net.core.wmem_max=8388608
  net.core.rmem_default=65536
  net.core.wmem_default=65536
  # net.ipv4.tcp_rmem='4096 87380 8388608'
  # net.ipv4.tcp_wmem='4096 65536 8388608'
  # net.ipv4.tcp_mem='8388608 8388608 8388608'
  net.ipv4.route.flush=1
  net.ipv4.ip_forward=1
  net.ipv4.conf.default.rp_filter=1
  vm.max_map_count=262144
EOF
    echo 127.0.1.1 $(hostname) >> /etc/hosts
    sysctl --system
    systemctl stop firewalld
    systemctl disable firewalld
    systemctl stop NetworkManager
    systemctl disable NetworkManager


    # open necessary k3s ports

    iptables -A INPUT -p tcp --match multiport --dports 2379:2380 -j ACCEPT
    iptables -A INPUT -p tcp --match multiport --dports 6443:6445 -j ACCEPT
    iptables -A INPUT -p tcp --match multiport --dports 10250:10255 -j ACCEPT
    iptables -I INPUT -p udp --dport 8472 -j ACCEPT
    iptables -A INPUT -p tcp --match multiport --dports 30000:32767 -j ACCEPT
}

# install pre-requisite packages/etc.  For true air-gap will need to consider downloading these rpms locally in the future.

install_prereqs() {
    yum localinstall ${artifact_dir}/rpms/*.rpm --disablerepo=* -y --nogpgcheck
}

precreate_dirs() {
    mkdir -p /etc/rancher/k3s
    mkdir -p /var/lib/rancher/k3s/agent/images
    if [[ "$nodetype" == "server" ]] ; then
        mkdir -p /var/lib/rancher/k3s/server/manifests
        mkdir -p /var/lib/rancher/k3s/server/static/charts
    else
        echo "agent node, skipping server manifest and charts"
    fi
}

copy_artifacts() {
    cp ${artifact_dir}/k3s /usr/local/bin/k3s
    chmod +x /usr/local/bin/k3s
    rsync -av --progress  ${artifact_dir}/k3s-airgap-images-amd64.tar /var/lib/rancher/k3s/agent/images/
}

install_k3s_server() {
    host_ip=$(ip a s ${k3s_interface} | egrep -o 'inet [0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | cut -d' ' -f2)
    INSTALL_K3S_SKIP_SELINUX_RPM=true INSTALL_K3S_SKIP_DOWNLOAD=true INSTALL_K3S_EXEC="--debug --write-kubeconfig-mode 664 --disable traefik --flannel-iface ${k3s_interface} --node-ip ${host_ip} --advertise-address ${host_ip} --kube-apiserver-arg kubelet-preferred-address-types=InternalIP,Hostname,ExternalIP --kubelet-arg=image-gc-high-threshold=95 --kubelet-arg=image-gc-low-threshold=90" ${artifact_dir}/k3s-install.sh

    cat /var/lib/rancher/k3s/server/node-token &> ~/node-token.new
}

install_k3s_agent() {
    if [[ -z "$k3s_server_url" ]] ; then
        echo "you must specify the k3s server URL with -s https://xx.xx.xx.xx:6443 when choosing the agent node type"
        exit 1
    elif [[ -z "$k3s_node_token" ]] ; then
        echo "you must specify the k3s node token with -t when choosing the agent node type"
        exit 1
    fi
    host_ip=$(ip a s ${k3s_interface} | egrep -o 'inet [0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | cut -d' ' -f2)
    rpm -Uvh ${artifact_dir}/rpms/k3s-selinux.noarch.rpm
    K3S_URL=${k3s_server_url} K3S_TOKEN=${k3s_node_token} INSTALL_K3S_SKIP_SELINUX_RPM=true INSTALL_K3S_SKIP_DOWNLOAD=true INSTALL_K3S_EXEC="--flannel-iface ${k3s_interface} --node-ip ${host_ip} --kubelet-arg=image-gc-high-threshold=95 --kubelet-arg=image-gc-low-threshold=90" ${artifact_dir}/k3s-install.sh
}

configure_os
install_prereqs
precreate_dirs
copy_artifacts
if [[ "$nodetype" = "server" ]] ; then
    install_k3s_server
else
    install_k3s_agent
fi
