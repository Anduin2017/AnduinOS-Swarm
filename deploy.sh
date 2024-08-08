#!/bin/bash

set -e

function install_docker() {
    curl -fsSL get.docker.com -o get-docker.sh
    CHANNEL=stable sh get-docker.sh
    rm get-docker.sh

    # Also install wsdd because it's required by some services
    sudo apt install wsdd -y
}

function disable_snap() {
    sudo systemctl disable --now snapd || true
    sudo apt purge -y snapd || true
    sudo rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd /usr/lib/snapd ~/snap || true
    cat << EOF | sudo tee -a /etc/apt/preferences.d/no-snap.pref
Package: snapd
Pin: release a=*
Pin-Priority: -10
EOF
    sudo chown root:root /etc/apt/preferences.d/no-snap.pref
}

function better_performance() {
    # Add user to sudoers
    if ! sudo grep -q "$USER ALL=(ALL) NOPASSWD:ALL" /etc/sudoers.d/$USER; then
        echo "Adding $USER to sudoers..."
        sudo mkdir -p /etc/sudoers.d
        sudo touch /etc/sudoers.d/$USER
        echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee -a /etc/sudoers.d/$USER
    fi

    # Tuning for better performance
    sudo sysctl -w net.core.rmem_max=2500000
    sudo sysctl -w net.core.wmem_max=2500000
    sudo sysctl -w net.ipv4.tcp_congestion_control=bbr
    sudo sysctl -w net.core.default_qdisc=fq
    sudo sysctl -w fs.inotify.max_user_instances=524288
    sudo sysctl -w fs.inotify.max_user_watches=524288
    sudo sysctl -w fs.inotify.max_queued_events=524288
    sudo sysctl -w fs.aio-max-nr=524288
    sudo sysctl -p

    # Disable swap
    sudo sudo swapoff -a

    # Disable snapd
    disable_snap

    # Set timezone to UTC
    sudo timedatectl set-timezone UTC

    # Install latest kernel and intel-media-va-driver
    DEBIAN_FRONTEND=noninteractive sudo apt update
    apt list --installed | grep -q linux-generic-hwe-22.04 || sudo apt install -y linux-generic-hwe-22.04

    # Install docker
    apt list --installed | grep -q docker-ce || install_docker

    # Install some basic tools
    sudo DEBIAN_FRONTEND=noninteractive apt install -y \
        apt-transport-https ca-certificates curl lsb-release \
        software-properties-common wget git tree zip unzip vim net-tools traceroute dnsutils htop iotop pcp

    # Clean docker cache (optional)
    # sudo docker system prune -a --volumes -f
}

function deploy() {
    sudo docker stack deploy -c "$1" "$2" --detach
}

function create_secret() {
    secret_name=$1
    known_secrets=$(sudo docker secret ls --format '{{.Name}}')
    if [[ $known_secrets != *"$secret_name"* ]]; then
        echo "Please enter $secret_name secret"
        read secret_value
        echo $secret_value | sudo docker secret create $secret_name -
    fi
}

function create_network() {
    network_name=$1
    subnet=$2
    known_networks=$(sudo docker network ls --format '{{.Name}}')
    if [[ $known_networks != *"$network_name"* ]]; then
        networkdId=$(sudo docker network create --driver overlay --subnet $subnet --scope swarm $network_name)
        echo "Network $network_name created with id $networkdId"
    fi
}

echo "Deploying the cluster"
better_performance

echo "Creating secrets..."
#create_secret frp-token

echo "Creating networks..."
create_network proxy_app 10.234.0.0/16

echo "Creating data folders..."
find . -name 'docker-compose.yml' | while read file; do
  awk '{if(/device:/) print $2}' "$file" | while read -r path; do
    echo "sudo mkdir -p \"$path\""
    sudo mkdir -p "$path"
  done
done

echo "Starting registry..."
deploy stacks/registry/docker-compose.yml registry # 8080

echo "Make sure the registry is ready..."
sleep 5 # Could not trust result in the first few seconds, because the old registry might still be running
while curl -s http://localhost:8080/ > /dev/null; [ $? -ne 0 ]; do
    echo "Waiting for registry(http://localhost:8080) to start..."
    sleep 1
done

echo "Prebuild images..."
echo "{ \"insecure-registries\":[\"localhost:8080\"] }" | sudo tee /etc/docker/daemon.json
mkdir -p ./images/sites/discovered && cp ./stacks/**/*.conf ./images/sites/discovered

echo "Building images..."
sudo docker build ./images/sites    -t localhost:8080/box_starting/local_sites:latest
sudo docker push localhost:8080/box_starting/local_sites:latest
sudo docker build ./images/mirror   -t localhost:8080/box_starting/local_mirror:latest
sudo docker push localhost:8080/box_starting/local_mirror:latest

echo "Starting incoming proxy..."
deploy stacks/incoming/docker-compose.yml incoming # 8080

echo "Make sure the registry is ready..."
sleep 5 # Could not trust result in the first few seconds, because the old registry might still be running
while curl -s https://hub.anduinos.com > /dev/null; [ $? -ne 0 ]; do
    echo "Waiting for registry (https://hub.anduinos.com) to start... ETA: 25s"
    sleep 1
done

echo "Deploying business stacks..."
find ./stacks -name 'docker-compose.yml' -print0 | while IFS= read -r -d '' file; do
    # Skip the registry and incoming stacks
    if [[ $file == *"registry"* ]]; then
        continue
    fi
    if [[ $file == *"incoming"* ]]; then
        continue
    fi
    
    deploy "$file" "$(basename "$(dirname "$file")")"

    sleep 10
done
