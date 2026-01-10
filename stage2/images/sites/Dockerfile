# ============================
# Prepare caddy Environment
FROM localhost:8080/public_mirror/caddy:builder AS caddy-build-env

RUN xcaddy build \
    --with github.com/ueffel/caddy-brotli \
    --with github.com/caddyserver/transform-encoder

# ============================
# Prepare Caddyfile build Environment
FROM localhost:8080/box_starting/local_ubuntu AS config-build-env
WORKDIR /app

# Install curl for fetching Cloudflare IPs and openssl for generating dummy certs
# Also download Cloudflare Origin Pull CA certificate for mTLS verification
RUN apt-get update && \
    apt-get install -y curl openssl && \
    mkdir -p /app/Dist/certs && \
    curl -o /app/Dist/certs/origin-pull-ca.pem https://developers.cloudflare.com/ssl/static/origin-pull-ca.pem && \
    rm -rf /var/lib/apt/lists/*

COPY . .

# Outputs to /app/Dist/Caddyfile
RUN chmod +x /app/build_proxy.sh
RUN /bin/bash /app/build_proxy.sh

# Generate dummy certificates for build-time validation
# These will be replaced by real certificates at runtime via Docker volumes
RUN openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout /app/Dist/certs/anduinos.key \
    -out /app/Dist/certs/anduinos.pem \
    -days 1 -subj "/CN=localhost"

# ============================
# Prepare Runtime Environment
FROM localhost:8080/public_mirror/caddy:latest

WORKDIR /app

EXPOSE 80 443

COPY --from=caddy-build-env /usr/bin/caddy /usr/bin/caddy
COPY --from=config-build-env /app/Dist/Caddyfile /etc/caddy/Caddyfile

# Copy dummy certificates to expected location for validation
# Note: These will be replaced by real certificates at runtime via Docker volumes
COPY --from=config-build-env /app/Dist/certs/anduinos.pem /data/caddy/certs/anduinos.pem
COPY --from=config-build-env /app/Dist/certs/anduinos.key /data/caddy/certs/anduinos.key

# Copy Cloudflare Origin Pull CA certificate for mTLS verification
COPY --from=config-build-env /app/Dist/certs/origin-pull-ca.pem /data/caddy/certs/origin-pull-ca.pem

# Now we can safely validate the Caddyfile with dummy certificates in place
RUN caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile && \
    mkdir -p /var/log/caddy /data/caddy/logs && \
    touch /data/caddy/logs/web.log

ENTRYPOINT ["sh", "-c", "caddy run --config /etc/caddy/Caddyfile --adapter caddyfile & tail -f /data/caddy/logs/web.log & wait"]
