# ============================
# Prepare caddy Environment
FROM localhost:8080/public_mirror/caddy:builder AS caddy-build-env

RUN xcaddy build \
    --with github.com/ueffel/caddy-brotli \
    --with github.com/caddyserver/transform-encoder \
    --with github.com/caddy-dns/cloudflare

# ============================
# Prepare Caddyfile build Environment
FROM localhost:8080/box_starting/local_ubuntu AS config-build-env
WORKDIR /app

# Install curl for fetching Cloudflare IPs
RUN apt-get update && \
    apt-get install -y curl ca-certificates && \
    mkdir -p /app/Dist && \
    rm -rf /var/lib/apt/lists/*

COPY . .

# Outputs to /app/Dist/Caddyfile
RUN chmod +x /app/build_proxy.sh
RUN /bin/bash /app/build_proxy.sh



# ============================
# Prepare Runtime Environment
FROM localhost:8080/public_mirror/caddy:latest

WORKDIR /app

EXPOSE 80 443

COPY --from=caddy-build-env /usr/bin/caddy /usr/bin/caddy
COPY --from=config-build-env /app/Dist/Caddyfile /etc/caddy/Caddyfile



# Now we can safely validate the Caddyfile with dummy certificates in place
# We inject a dummy token here just to pass the validation check during build.
# The real token will be provided at runtime via Docker Service environment variables.
# Note: The token must look like a valid Cloudflare token (approx 40 chars) to pass validation.
RUN CLOUDFLARE_API_TOKEN=ThisIsAFakeTokenForValidationOnly123456 caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile && \
    mkdir -p /var/log/caddy /data/caddy/logs && \
    touch /data/caddy/logs/web.log

ENTRYPOINT ["sh", "-c", "caddy run --config /etc/caddy/Caddyfile --adapter caddyfile & tail -f /data/caddy/logs/web.log & wait"]
