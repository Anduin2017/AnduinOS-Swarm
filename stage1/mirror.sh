set -euo pipefail

mirror_image() {
    local image="$1"
    local target="localhost:8080/public_mirror/${image}"

    echo "Mirroring image: $image"
    sudo docker pull "$image"
    sudo docker tag "$image" "$target"
    sudo docker push "$target"
}

echo "Mirroring Ubuntu..."
mirror_image "ubuntu:25.04"

echo "Mirroring Caddy builder..."
mirror_image "caddy:builder"

echo "Mirroring Caddy latest..."
mirror_image "caddy:latest"

