# ============================
# Prepare caddy Environment
FROM caddy:builder AS caddy-build-env

RUN xcaddy build \
    --with github.com/ueffel/caddy-brotli \
    --with github.com/caddyserver/transform-encoder

# ============================
# Prepare Caddyfile build Environment
FROM ubuntu:22 AS config-build-env
WORKDIR /app
COPY . .

# Outputs to /app/Dist/Caddyfile
RUN chmod +x /app/build_proxy.sh
RUN /bin/bash /app/build_proxy.sh

# ============================
# Prepare Runtime Environment
FROM caddy

WORKDIR /app

EXPOSE 80 443

COPY --from=caddy-build-env /usr/bin/caddy /usr/bin/caddy
COPY --from=config-build-env /app/Dist/Caddyfile /etc/caddy/Caddyfile

# Check if any fatal errors in caddyfile
RUN caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile && \
    mkdir -p /var/log/caddy && \
    touch /var/log/caddy/caddy.log

ENTRYPOINT ["sh", "-c", "caddy run --config /etc/caddy/Caddyfile --adapter caddyfile & tail -f /var/log/caddy/caddy.log & wait"]