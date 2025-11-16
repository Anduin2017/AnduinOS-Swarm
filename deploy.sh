#!/bin/bash
set -euo pipefail
#==========================
# Color
#==========================
export Green="\033[32m"
export Red="\033[31m"
export Yellow="\033[33m"
export Blue="\033[36m"
export Font="\033[0m"
export GreenBG="\033[42;37m"
export RedBG="\033[41;37m"
export INFO="${Blue}[ INFO ]${Font}"
export OK="${Green}[  OK  ]${Font}"
export ERROR="${Red}[FAILED]${Font}"
export WARNING="${Yellow}[ WARN ]${Font}"

#==========================
# Argument Parsing
#==========================
STACK_FILTER=""
# Use ${1:-} and ${2:-} to provide a default empty value if arguments are not set
if [[ "${1:-}" == "--filter" ]] && [[ -n "${2:-}" ]]; then
  STACK_FILTER="$2"
  echo -e "${Green}[  OK  ]${Font} ${Blue} Running with filter, will only deploy stacks containing: '$STACK_FILTER'${Font}"
  shift 2 # Consume the two arguments so they don't interfere with other parts of the script
fi

#==========================
# Print Colorful Text
#==========================
function print_ok() {
  echo -e "${OK} ${Blue} $1 ${Font}"
}

function print_info() {
  echo -e "${INFO} ${Font} $1"
}

function print_error() {
  echo -e "${ERROR} ${Red} $1 ${Font}"
}

function print_warn() {
  echo -e "${WARNING} ${Yellow} $1 ${Font}"
}

function judge() {
  if [[ 0 -eq $? ]]; then
    print_ok "$1 succeeded"
    sleep 0.2
  else
    print_error "$1 failed"
    exit 1
  fi
}

# Determine which env file to use
if [ -f ".env.prod" ]; then
    ENV_FILE=".env.prod"
    print_ok "Using .env.prod for configuration."
elif [ -f ".env" ]; then
    ENV_FILE=".env"
    print_warn "Using .env for configuration."
else
    ENV_FILE=""
    print_ok "No .env or .env.prod file found. Proceeding without variable substitution."
fi

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
    if ! command -v docker >/dev/null; then
        install_docker
    else
        print_ok "Docker is already installed."
    fi

    # Init docker swarm if not initialized
    sudo docker info | grep -q "Swarm: active" || init_docker_swarm

    # Add user to docker group
    sudo usermod -aG docker $USER
}

function ensure_packages_needed_ready() {
    sudo DEBIAN_FRONTEND=noninteractive apt install -y wsdd valgrind curl wget apt-transport-https ca-certificates

    # Install yq. (Run install_yq only if the /usr/bin/yq does not exist.)
    [ -f /usr/bin/yq ] || install_yq

    # Install docker
    ensure_docker_ready
}

function ensure_nvidia_gpu() {
    # ensure /usr/bin/nvidia-smi exists
    if [ ! -f /usr/bin/nvidia-smi ]; then
        local doc_link=https://docs.anduinos.com/Applications/Development/Docker/Docker.html
        print_error "Please install Nvidia driver. See $doc_link for more information."
        exit 1
    fi

    ulimit -n 65535
    valgrind /usr/bin/nvidia-smi -L 2> /dev/null | grep -q "GPU 0" || {
        local doc_link=https://docs.anduinos.com/Applications/Development/Docker/Docker.html
        print_error "Please ensure you have Nvidia GPU. See $doc_link for more information."
        exit 1
    }

    # ensure package: nvidia-container-toolkit and nvidia-docker2
    apt list --installed | grep -q nvidia-container-toolkit || {
        local doc_link=https://docs.anduinos.com/Applications/Development/Docker/Docker.html
        print_error "Please install nvidia-container-toolkit and nvidia-docker2. See $doc_link for more information."
        exit 1
    }
}

better_performance() {
    # Avoid system sleep (If gsettings command exists)
    if command -v gsettings &>/dev/null; then
        print_warn "Disabling sleep via gsettings..."
        gsettings set org.gnome.desktop.session idle-delay 0 || true
        gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' || true
        gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing' || true
    fi

    sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

    print_ok "Applying runtime sysctl tweaks for performance..."
    sudo sysctl -w net.core.rmem_max=2500000
    sudo sysctl -w net.core.wmem_max=2500000
    sudo sysctl -w net.ipv4.tcp_congestion_control=bbr
    sudo sysctl -w net.core.default_qdisc=fq
    sudo sysctl -w fs.inotify.max_user_instances=524288
    sudo sysctl -w fs.inotify.max_user_watches=524288
    sudo sysctl -w fs.inotify.max_queued_events=524288
    sudo sysctl -w fs.aio-max-nr=2097152

    print_ok "Setting system timezone to UTC..."
    sudo timedatectl set-timezone UTC

    print_ok "Setting up swap file equal to physical RAM size..."
    curl -s https://gitlab.aiursoft.com/anduin/init-server/-/raw/master/autoswap.sh?ref_type=heads | sudo bash
}

function clean_up_docker() {
    # if there is no stack deployed, run the system prune command
    # else, log and skip cleaning.
    if [ $(sudo docker stack ls --format '{{.Name}}' | wc -l) -eq 0 ]; then
        print_warn "Seems running on a new cluster. Cleaning up docker..."
        sudo docker system prune -a --volumes -f
        sudo docker network prune -f
        #sudo docker builder prune -f
    else
        print_ok "There are stacks already deployed and running. Skip cleaning."
    fi
}

function create_secret() {
    local secret_name=$1
    if ! sudo docker secret ls --format '{{.Name}}' | grep -Fxq "$secret_name"; then
        local secret_value
        if [ -t 0 ]; then
          read -rs -p "Enter value for secret '$secret_name': " secret_value
          echo
        else
          read -rs -p "Enter value for secret '$secret_name': " secret_value < /dev/tty
          echo
        fi

        printf '%s' "$secret_value" | sudo docker secret create "$secret_name" -
    fi
}

function create_network() {
    network_name=$1
    subnet=$2
    known_networks=$(sudo docker network ls --format '{{.Name}}')
    if [[ $known_networks != *"$network_name"* ]]; then
        print_warn "Creating network $network_name with subnet $subnet..."
        networkId=$(sudo docker network create --driver overlay --attachable --subnet $subnet --scope swarm $network_name)
        print_ok "Network $network_name created with id $networkId"
    fi
}

function deploy() {
    local original_compose_file=$1
    local stack_name=$2
    local temp_compose_file=$(mktemp)

    # Always copy to a temporary file to avoid modifying the original
    cp "$original_compose_file" "$temp_compose_file"

    # If an environment file is found, perform substitutions
    if [ -n "$ENV_FILE" ]; then
        # Read non-empty, non-comment lines from the env file
        grep -v -e '^#' -e '^$' "$ENV_FILE" | while IFS='=' read -r key value; do
            # Escape slashes and ampersands for sed
            escaped_value=$(printf '%s\n' "$value" | sed -e 's/[\/&]/\\&/g')
            # Use a different delimiter for sed to handle special characters in values
            sed -i "s/{{$key}}/$escaped_value/g" "$temp_compose_file"
        done
    fi

    print_ok "Deploying stack '$stack_name' with compose file '$original_compose_file'..."
    sudo docker stack deploy -c "$temp_compose_file" "$stack_name" --detach --prune --with-registry-auth

    # Clean up the temporary file
    rm "$temp_compose_file"
}

# Ensure packages needed are ready
print_ok "Ensure packages needed are ready..."
ensure_packages_needed_ready

# Ensure has Nvidia GPU and have installed nvidia-container-toolkit and nvidia-docker2
print_ok "Ensure has Nvidia GPU and have installed..."
if [ -f /usr/bin/nvidia-smi ]; then
    ensure_nvidia_gpu
else
    print_warn "Nvidia GPU not found. Skipping Nvidia GPU configuration. GPU pass-through will not be available."
fi

# Tuning for better performance
print_ok "Tuning for better performance..."
better_performance

print_ok "Cleaning up docker (if no stack deployed)..."
clean_up_docker

print_ok "Creating secrets..."
while IFS= read -r file; do
  while IFS= read -r secret_name; do
    if [ -n "$secret_name" ]; then
      print_ok "Creating secret $secret_name..."
      create_secret "$secret_name"
    fi
  done < <(yq eval '.secrets | to_entries | .[] | select(.value.external == true) | .key' "$file")
done < <(find ./stage* -name 'docker-compose.yml' -type f)

print_ok "Creating networks..."
subnet_third_octet=233
external_networks=$(find ./stage* -name 'docker-compose.yml' -type f | xargs yq eval '.networks | to_entries | .[] | select(.value.external == true) | .key' 2>/dev/null | sort | uniq)
for network in $external_networks; do
  if [ "$network" == "---" ]; then
    continue
  fi
  print_ok "Ensuring network $network exists..."
  create_network "$network" "10.${subnet_third_octet}.0.0/16"
  subnet_third_octet=$((subnet_third_octet + 1))
done

print_ok "Creating data folders..."
find . -name 'docker-compose.yml' | while read file; do
  awk '{if(/device:/) print $2}' "$file" | while read -r path; do
    sudo mkdir -p "$path"
  done
done

#=============================
# Nvidia GPU Part
#=============================
if [ -f /usr/bin/nvidia-smi ]; then
  print_ok "Configuring docker daemon for Nvidia GPU..."
  GPU_IDS=$(valgrind /usr/bin/nvidia-smi -a 2> /dev/null | grep "GPU UUID" | awk '{print substr($4,5,36)}')
  print_ok "Detected GPU UUIDs:"
  print_ok "$GPU_IDS"
  JSON_GPU_RESOURCES=""
  for ID in $GPU_IDS; do
      JSON_GPU_RESOURCES+="\"NVIDIA-GPU=$ID\","
  done
  JSON_GPU_RESOURCES=${JSON_GPU_RESOURCES%,}  # 去掉最后一个逗号

  if [ -f /etc/docker/daemon.json ]; then
      old_hash_daemon=$(sha256sum /etc/docker/daemon.json | awk '{print $1}')
  else
      old_hash_daemon=""
  fi

  if [ -f /etc/nvidia-container-runtime/config.toml ]; then
      old_hash_nvidia=$(sha256sum /etc/nvidia-container-runtime/config.toml | awk '{print $1}')
  else
      old_hash_nvidia=""
  fi

  sudo tee /etc/docker/daemon.json > /dev/null <<EOF
{
  "runtimes": {
    "nvidia": {
      "path": "/usr/bin/nvidia-container-runtime",
      "runtimeArgs": []
    }
  },
  "default-runtime": "nvidia",
  "node-generic-resources": [
    $JSON_GPU_RESOURCES
  ],
  "insecure-registries": [
    "localhost:8080"
  ]
}
EOF
  sudo sed -i 's/#swarm-resource = "DOCKER_RESOURCE_GPU"/swarm-resource = "DOCKER_RESOURCE_GPU"/' /etc/nvidia-container-runtime/config.toml

  new_hash_daemon=$(sha256sum /etc/docker/daemon.json | awk '{print $1}')
  new_hash_nvidia=$(sha256sum /etc/nvidia-container-runtime/config.toml | awk '{print $1}')
  if [ "$old_hash_daemon" != "$new_hash_daemon" ] || [ "$old_hash_nvidia" != "$new_hash_nvidia" ]; then
      print_warn "Configuration files changed. Restarting docker service..."
      sudo systemctl restart docker.service
  else
      print_ok "Configuration files not changed."
  fi
else
  print_warn "Nvidia GPU not found. Skipping Nvidia GPU configuration. GPU pass-through will not be available."
fi
#=============================
# Nvidia GPU Part end
#=============================

print_warn "=============================================================================="
print_warn "   Starting stage 0: Mission is to start a simple registry"
print_warn "=============================================================================="
sleep 3

sudo docker compose -f ./stage0/registry/docker-compose.yml up -d --pull always --no-recreate --remove-orphans

#deploy stage0/registry/docker-compose.yml registry # 8080

print_ok "Make sure the registry is ready..."
sleep 5 # Could not trust result in the first few seconds, because the old registry might still be running
while curl -s http://localhost:8080/ > /dev/null; [ $? -ne 0 ]; do
    print_warn "Waiting for registry(http://localhost:8080/) to start..."
    sleep 1
done

print_warn "=============================================================================="
print_warn "   Ending stage 0: Registry is ready at http://localhost:8080/"
print_warn ""
print_warn "   Starting stage 1: Mission is to mirror public images to the simple registry"
print_warn "=============================================================================="
sleep 3

bash ./stage1/mirror.sh

print_warn "=============================================================================="
print_warn "   Ending stage 1: Images are mirrored."
print_warn ""
print_warn "   Starting stage 2: Mission is to build and start basic web infrastructure"
print_warn "=============================================================================="
sleep 3

rm -rf ./stage2/images/sites/discovered
mkdir -p ./stage2/images/sites/discovered && \
    cp ./stage2/stacks/**/*.conf ./stage2/images/sites/discovered && \
    cp ./stage3/stacks/**/*.conf ./stage2/images/sites/discovered && \
    cp ./stage4/stacks/**/*.conf ./stage2/images/sites/discovered

print_ok "Building local ubuntu..."
sudo docker build ./stage2/images/ubuntu   -t localhost:8080/box_starting/local_ubuntu:latest
sudo docker push localhost:8080/box_starting/local_ubuntu:latest
print_ok "Building local frp..."
sudo docker build ./stage2/images/frp      -t localhost:8080/box_starting/local_frp:latest
sudo docker push localhost:8080/box_starting/local_frp:latest
print_ok "Building local caddy..."
sudo docker build ./stage2/images/sites    -t localhost:8080/box_starting/local_sites:latest
sudo docker push localhost:8080/box_starting/local_sites:latest
print_ok "Building local pysyncer..."
sudo docker build ./stage2/images/pysyncer    -t localhost:8080/box_starting/local_pysyncer:latest
sudo docker push localhost:8080/box_starting/local_pysyncer:latest

print_ok "Starting incoming proxy..."
deploy stage2/stacks/incoming/docker-compose.yml incoming # 8080

print_ok "Make sure the caddy is ready..."
sleep 5 # Could not trust result in the first few seconds, because the old registry might still be running
while curl -s http://test.aiursoft.com > /dev/null; [ $? -ne 0 ]; do
    print_warn "Waiting for caddy (http://test.aiursoft.com) to start... ETA: 25s"
    sleep 1
done

print_warn "=============================================================================="
print_warn "   Ending stage 2: Basic web infrastructure is ready."
print_warn ""
print_warn "   Starting stage 3: Mission is to build and start Authentik and Zot"
print_warn "=============================================================================="
sleep 3

print_ok "Building local zot..."
sudo docker build ./stage3/images/zot -t localhost:8080/box_starting/local_zot:latest
sudo docker push localhost:8080/box_starting/local_zot:latest

print_ok "Starting Authentik and Zot..."
deploy stage3/stacks/authentik/docker-compose.yml authentik
deploy stage3/stacks/zot/docker-compose.yml zot

print_ok "Making sure the authentik is ready..."
while curl -s https://auth.aiursoft.com > /dev/null; [ $? -ne 0 ]; do
    print_warn "Waiting for authentik (https://auth.aiursoft.com) to start... ETA: 25s"
    sleep 1
done

print_ok "Making sure the zot is ready..."
sleep 5 # Could not trust result in the first few seconds, because the old zot might still be running
while curl -s https://hub.aiursoft.com > /dev/null; [ $? -ne 0 ]; do
    print_warn "Waiting for registry (https://hub.aiursoft.com) to start... ETA: 25s"
    sleep 1
done

print_warn "=============================================================================="
print_warn "   Ending stage 3: Authentik and Zot are ready."
print_warn ""
print_warn "   Starting stage 4: Mission is to deploy business stacks"
print_warn "=============================================================================="
sleep 3

print_ok "Deploying business stacks..."
serviceCount=$(sudo docker service ls --format '{{.Name}}' | wc -l | awk '{print $1}')

find ./stage4 -name 'docker-compose.yml' -print0 | while IFS= read -r -d '' file; do
    # Extract the stack name from the file path (e.g., ./stage4/gitlab/docker-compose.yml -> gitlab)
    stack_name=$(basename "$(dirname "$file")")

    # Check if a filter is active, and if the stack name matches the filter
    if [ -z "$STACK_FILTER" ] || [[ "$stack_name" == *"$STACK_FILTER"* ]]; then
        print_ok "Deploying stack: $stack_name"
        deploy "$file" "$stack_name"

        # If it's a new cluster, slow down the deployment to avoid overwhelming the system
        if [ $serviceCount -lt 10 ]; then
            sleep 10
        fi
    else
        print_info "Skipping stack '$stack_name' due to filter."
    fi
done
