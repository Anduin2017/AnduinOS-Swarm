#!/bin/bash

set -e

function install_yq() {
    local download_link="https://github.com/mikefarah/yq/releases/download/v4.45.1/yq_linux_amd64"
    sudo wget -O /usr/bin/yq "$download_link"
    sudo chmod +x /usr/bin/yq
}

function install_docker() {
    curl -fsSL get.docker.com -o get-docker.sh
    CHANNEL=stable sh get-docker.sh
    rm get-docker.sh
}

function init_docker_swarm() {
    sudo docker swarm init --advertise-addr $(hostname -I | awk '{print $1}')
}

function ensure_docker_ready() {
    # Install docker if not installed
    apt list --installed | grep -q docker-ce || install_docker

    # Init docker swarm if not initialized
    sudo docker info | grep -q "Swarm: active" || init_docker_swarm

    # Add user to docker group
    sudo usermod -aG docker $USER
}

function ensure_packages_needed_ready() {
    sudo DEBIAN_FRONTEND=noninteractive apt install -y wsdd valgrind curl wget apt-transport-https ca-certificates software-properties-common

    # Install yq. (Run install_yq only if the /usr/bin/yq does not exist.)
    [ -f /usr/bin/yq ] || install_yq

    # Install docker
    ensure_docker_ready
}

function better_performance() {
    # Avoid system sleep (If gsettings command exists)
    if command -v gsettings &> /dev/null; then
        echo "Avoid system sleep..."
        gsettings set org.gnome.desktop.session idle-delay 0
        gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
        gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing'
    fi
    sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

    # Tuning for better performance
    sudo sysctl -w net.core.rmem_max=2500000
    sudo sysctl -w net.core.wmem_max=2500000
    sudo sysctl -w net.ipv4.tcp_congestion_control=bbr
    sudo sysctl -w net.core.default_qdisc=fq
    sudo sysctl -w fs.inotify.max_user_instances=524288
    sudo sysctl -w fs.inotify.max_user_watches=524288
    sudo sysctl -w fs.inotify.max_queued_events=524288
    sudo sysctl -w fs.aio-max-nr=2097152
    sudo sysctl -p

    # Set timezone to UTC
    sudo timedatectl set-timezone UTC
}

function clean_up_docker() {
    # if there is no stack deployed, run the system prune command
    # else, log and skip cleaning.
    if [ $(sudo docker stack ls --format '{{.Name}}' | wc -l) -eq 0 ]; then
        echo "Seems running on a new cluster. Cleaning up docker..."
        sudo docker system prune -a --volumes -f
        #sudo docker builder prune -f
    else
        echo "There are stacks already deployed and running. Skip cleaning."
    fi
}

function create_secret() {
    local secret_name=$1
    local known_secrets=$(sudo docker secret ls --format '{{.Name}}')
    if [[ $known_secrets != *"$secret_name"* ]]; then
        echo "Please enter $secret_name secret"
        read -s secret_value
        echo $secret_value | sudo docker secret create $secret_name -
    fi
}

function create_network() {
    network_name=$1
    subnet=$2
    known_networks=$(sudo docker network ls --format '{{.Name}}')
    if [[ $known_networks != *"$network_name"* ]]; then
        networkId=$(sudo docker network create --driver overlay --attachable --subnet $subnet --scope swarm $network_name)
        echo "Network $network_name created with id $networkId"
    fi
}

function deploy() {
    sudo docker stack deploy -c "$1" "$2" --detach --prune
}

# Ensure packages needed are ready
echo "Ensure packages needed are ready..."
ensure_packages_needed_ready

echo "Tuning for better performance..."
better_performance

echo "Cleaning up docker (if no stack deployed)..."
clean_up_docker

echo "Creating secrets..."
find ./stacks -name 'docker-compose.yml' -type f | while read -r file; do
  yq eval '.secrets | to_entries | .[] | select(.value.external == true) | .key' "$file" | while read -r secret_name; do
    if [ -n "$secret_name" ]; then
      echo "Creating secret $secret_name..."
      create_secret "$secret_name"
    fi
  done
done

echo "Creating networks..."
subnet_third_octet=233
external_networks=$(find ./stacks -name 'docker-compose.yml' -type f | xargs yq eval '.networks | to_entries | .[] | select(.value.external == true) | .key' 2>/dev/null | sort | uniq)
for network in $external_networks; do
  if [ "$network" == "---" ]; then
    continue
  fi
  echo "Creating network $network ... on subnet 10.${subnet_third_octet}.0.0/16"
  create_network "$network" "10.${subnet_third_octet}.0.0/16"
  subnet_third_octet=$((subnet_third_octet + 1))
done

echo "Creating data folders..."
find . -name 'docker-compose.yml' | while read file; do
  awk '{if(/device:/) print $2}' "$file" | while read -r path; do
    sudo mkdir -p "$path" && echo "Created $path"
  done
done

echo "Opening firewall ports..."
find . -name 'docker-compose.yml' | while read -r file; do
  yq eval -r '.services[].ports[]? | select(has("published")) | "\(.published) \(.protocol)"' "$file" | while read -r published protocol; do
    if [ -z "$protocol" ]; then
      continue
    else
      sudo ufw allow "${published}/${protocol}" && echo "Allowed ${published}/${protocol}"
    fi
  done
done

sudo tee /etc/docker/daemon.json > /dev/null <<EOF
{
  "insecure-registries": [
    "localhost:8080"
  ]
}
EOF

# #=============================
# # Nvidia GPU Part
# #=============================
# echo "Configuring docker daemon for Nvidia GPU..."
# GPU_IDS=$(valgrind /usr/bin/nvidia-smi -a 2> /dev/null | grep "GPU UUID" | awk '{print substr($4,5,36)}')
# echo "Detected GPU UUIDs:"
# echo "$GPU_IDS"
# JSON_GPU_RESOURCES=""
# for ID in $GPU_IDS; do
#     JSON_GPU_RESOURCES+="\"NVIDIA-GPU=$ID\","
# done
# JSON_GPU_RESOURCES=${JSON_GPU_RESOURCES%,}  # 去掉最后一个逗号

# if [ -f /etc/docker/daemon.json ]; then
#     old_hash_daemon=$(sha256sum /etc/docker/daemon.json | awk '{print $1}')
# else
#     old_hash_daemon=""
# fi

# if [ -f /etc/nvidia-container-runtime/config.toml ]; then
#     old_hash_nvidia=$(sha256sum /etc/nvidia-container-runtime/config.toml | awk '{print $1}')
# else
#     old_hash_nvidia=""
# fi

# sudo tee /etc/docker/daemon.json > /dev/null <<EOF
# {
#   "runtimes": {
#     "nvidia": {
#       "path": "/usr/bin/nvidia-container-runtime",
#       "runtimeArgs": []
#     }
#   },
#   "default-runtime": "nvidia",
#   "node-generic-resources": [
#     $JSON_GPU_RESOURCES
#   ],
#   "insecure-registries": [
#     "localhost:8080"
#   ]
# }
# EOF
# sudo sed -i 's/#swarm-resource = "DOCKER_RESOURCE_GPU"/swarm-resource = "DOCKER_RESOURCE_GPU"/' /etc/nvidia-container-runtime/config.toml

# new_hash_daemon=$(sha256sum /etc/docker/daemon.json | awk '{print $1}')
# new_hash_nvidia=$(sha256sum /etc/nvidia-container-runtime/config.toml | awk '{print $1}')
# if [ "$old_hash_daemon" != "$new_hash_daemon" ] || [ "$old_hash_nvidia" != "$new_hash_nvidia" ]; then
#     echo "Configuration files changed. Restarting docker service..."
#     sudo systemctl restart docker.service
# else
#     echo "Configuration files not changed."
# fi
# #=============================
# # Nvidia GPU Part end
# #=============================

echo "Starting registry..."
deploy stacks/registry/docker-compose.yml registry # 8080

echo "Make sure the registry is ready..."
sleep 15 # Could not trust result in the first few seconds, because the old registry might still be running
while curl -s http://localhost:8080/ > /dev/null; [ $? -ne 0 ]; do
    echo "Waiting for registry(http://localhost:8080) to start..."
    sleep 1
done

echo "Prebuild images..."
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
serviceCount=$(sudo docker service ls --format '{{.Name}}' | wc -l | awk '{print $1}')
find ./stacks -name 'docker-compose.yml' -print0 | while IFS= read -r -d '' file; do
    # Skip the registry and incoming stacks
    if [[ $file == *"registry"* ]]; then
        continue
    fi
    if [[ $file == *"incoming"* ]]; then
        continue
    fi
    
    deploy "$file" "$(basename "$(dirname "$file")")"

    # If serviceCount < 10, which means this is a new cluster. Sleep 10 to slow down the deployment.
    if [ $serviceCount -lt 10 ]; then
        sleep 10
    fi
done
