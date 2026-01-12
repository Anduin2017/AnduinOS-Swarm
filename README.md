# AnduinOS Swarm

![Man hours](https://manhours.aiursoft.com/r/gitlab.aiursoft.com/anduin/anduinos-swarm.svg)

This is the docker swarm setup for AnduinOS.

这是一个容器唤起系统，能够一键配置并运行 AnduinOS 相关的服务。它基于 Cloudflare + Caddy + Docker Swarm + Py_Syncer + ClickHouse + ASP.NET Core 技术栈。

## 上 Cloudflare

上 Cloudflare 其实很简单。只需要亿步即可完成：

* 注册cloudflare
* 让cloudflare管理域名
* 让业务域名设置到真实IP上
* 删除caddy侧的限流。让cloudflare去处理限流。
* 让caddy信任cloudflare的IP作为代理。开发插件下载cloudflare ip来信任它们。
* 下载cloudflare的origin server证书到caddy，让caddy返回cloudflare的证书。这样外部如果不小心连上了我的caddy就会红。
* 在cloudflare TLS overview那里，改为 Current encryption mode: Full (strict)。这样强制cloudflare只信任这张证书。
* 增加caddy规则来禁止非cloudflare请求。下载cloudflare的公钥并要求mtls验证。开启：Authenticated Origin Pulls。实现黑客完全无法在override hostname+ip的情况下请求服务器。
* 让caddy把请求转发给业务应用的时候，取cloudflare的IP发给业务应用，并进行日志。优雅的处理cloudflare的ip。
* py_syncer去消费client ip而不是remote_ip，从而在日志和统计中出现真实的IP。

```mermaid
graph TD
    %% 定义样式
    classDef good fill:#d4edda,stroke:#28a745,stroke-width:2px;
    classDef bad fill:#f8d7da,stroke:#dc3545,stroke-width:2px;
    classDef cf fill:#fff3cd,stroke:#ffc107,stroke-width:2px;
    classDef server fill:#e2e3e5,stroke:#6c757d,stroke-width:2px;

    %% 角色
    Hacker[🔴 黑客/扫描器]:::bad
    User[🟢 真实用户]:::good
    
    %% Cloudflare 层
    subgraph Cloudflare_Edge [Cloudflare 边缘网络]
        CF_WAF[🛡️ WAF & DDoS 防护]:::cf
        CF_Cert[📜 客户端证书 mTLS Key]:::cf
    end

    %% 你的服务器层
    subgraph Anduin_Server [AnduinOS Swarm Server]
        direction TB
        FW[🔥 防火墙 443 Port]:::server
        
        subgraph Caddy_Container [Caddy Container]
            Caddy_TLS[🔒 mTLS 验证]:::server
            Caddy_Trust[🤝 Trusted Proxies IP还原]:::server
            Origin_Cert[📄 Origin CA 证书]:::server
        end
        
        subgraph App_Layer [业务应用层]
            WebApp[ASP.NET Core App]:::good
            PySyncer[🐍 PySyncer]:::good
        end
        
        DB[(ClickHouse)]:::server
    end

    %% 流量路径 - 正常用户
    User -->|HTTPS| CF_WAF
    CF_WAF -->|携带 Client Cert| FW
    FW --> Caddy_TLS
    Caddy_TLS -- "验证通过 (有证书)" --> Caddy_Trust
    Caddy_Trust -- "解析出 Client IP: 4.145.x.x" --> WebApp
    Caddy_Trust -- "JSON Log (Client IP)" --> PySyncer
    PySyncer -->|写入真实IP| DB

    %% 流量路径 - 黑客
    Hacker -.->|直连 IP 无证书| FW
    FW -.-> Caddy_TLS
    Caddy_TLS -- "❌ 拒绝连接 (Handshake Fail)" --> Hacker
    
    %% 补充说明
    note1[Cloudflare 负责限流 & 挡住第一波攻击] --- CF_WAF
    note2[Caddy 负责物理阻断非 CF 流量] --- Caddy_TLS
    note3[全链路加密 Full Strict] --- Origin_Cert

    linkStyle 6,7,8 stroke:#28a745,stroke-width:2px;
    linkStyle 9,10,11 stroke:#dc3545,stroke-width:2px,stroke-dasharray: 5 5;
```

Cloudflare 需要管理的设置：

* DNS -> Settings -> DNS SEC -> On
* Security -> Settings -> Bot Fight Mode -> On
* Security -> Settings -> AI Labyrinth -> On
* Secuirty -> Settings -> Browser integrity check -> On
* SSL/TLS -> Current encryption mode -> Full **Strict**
* SSL/TLS -> Edge Certificates -> HSTS -> On
* SSL/TLS -> Edge Certificates -> Minimum TLS Version -> 1.2
* SSL/TLS -> Edge Certificates -> Always Use HTTPS -> On
* SSL/TLS -> Origin Server -> Authenticated Origin Pulls -> On
* Speed -> Settings -> Protocol Optimization -> HTTP3 -> On
* Speed -> Settings -> Protocol Optimization -> 0-RTT Connection Resumption -> On
* Speed -> Settings -> Content Optimization -> Rocket Loader -> Off
* Account -> Analytics & Logs -> Web analytics -> Manage site -> Advanced -> Delete
* Caching -> Tiered Cache -> Smart
* Caching -> Cache Rules -> Create rule -> Cache default file extensions -> Deploy
* Caching -> Configuration -> Crawler Hints
* Network -> IPv6 Compatibility -> On
* Network -> WebSockets -> On
* Network -> IP Geolocation -> On
* Scrape Shield -> Email Address Obfuscation -> On

折腾 Cloudflare 的设置的同时，我们也要对应调整好 Caddy。

## Caddy 的配置

首先编译 Caddy 的时候，大概流程如下：

* 先编译二进制
* 再生成配置文件。配置文件分三步：
  * cloudflare 的IP表
  * 基准区
  * 业务代码区
* 再生成一个假证书，方便caddy去验证。
* 最后把真证书（Cloudflare下发的）分给Caddy。

Caddy **放弃** 办理HTTPS证书！！但是仍然开启HTTPS，使用Cloudflare的证书！

Caddy **无法被非Cloudflare访问**！Caddy 强制客户端 mTLS！Caddy每次请求都要验证 Cloudflre 的证书！

Caddy **只信任Cloudflare** 作为前置代理！

```Dockerfile
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
    apt-get install -y curl openssl ca-certificates && \
    mkdir -p /app/Dist/certs && \
    curl -fsSL -o /app/Dist/certs/origin-pull-ca.pem https://developers.cloudflare.com/ssl/static/authenticated_origin_pull_ca.pem && \
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

# Copy Cloudflare Origin Pull CA certificate to /etc/caddy (safe from volume mount)
COPY --from=config-build-env /app/Dist/certs/origin-pull-ca.pem /etc/caddy/origin-pull-ca.pem

# Now we can safely validate the Caddyfile with dummy certificates in place
RUN caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile && \
    mkdir -p /var/log/caddy /data/caddy/logs && \
    touch /data/caddy/logs/web.log

ENTRYPOINT ["sh", "-c", "caddy run --config /etc/caddy/Caddyfile --adapter caddyfile & tail -f /data/caddy/logs/web.log & wait"]
```

上面的Dockerfile先不要立刻编译。有大量的东西我还没解释。

显然，

```bash
apt-get update && \
apt-get install -y curl openssl ca-certificates && \
mkdir -p /app/Dist/certs && \
curl -fsSL -o /app/Dist/certs/origin-pull-ca.pem https://developers.cloudflare.com/ssl/static/authenticated_origin_pull_ca.pem && \
rm -rf /var/lib/apt/lists/*
```

是为了下载 Cloudflare 的证书。这是一张公钥，Cloudflare 每次请求的时候，会使用他的私钥加密数据。这可以使得 Caddy 强制作为 Cloudflare 的傀儡。

过程：`/app/build_proxy.sh`非常复杂，内部分三步。

```bash
#!/bin/bash
set -e

echo "Building Caddyfile at $(pwd)..."
mkdir -p ./Dist

echo "Fetching Cloudflare IP ranges..."
chmod +x ./fetch_cloudflare_ips.sh
./fetch_cloudflare_ips.sh

echo "Adding empty lines to the end of files without a newline..."
find . -type f -name '*.conf' ! -name 'cloudflare_ips.conf' | while read -r file; do
    last_line=$(tail -n 1 "$file")
    if [[ -n "$last_line" ]]; then
        echo "" >> "$file"
        echo "修复文件结尾：$file"
    fi
done

echo "Building sites under $(pwd)..."
find . -type f -name "*.conf" ! -name "cloudflare_ips.conf" | while read -r file; do cat "$file"; echo -e "\n\n"; done | tee ./Dist/Sites.temp > /dev/null

echo "Appending cloudflare ips, baseline and business sites into final Caddyfile..."
(cat ./cloudflare_ips.conf; echo -e "\n\n"; cat ./baseline; echo -e "\n\n"; cat ./Dist/Sites.temp) | tee ./Dist/Caddyfile > /dev/null

echo "Caddyfile built."
ls ./Dist/ -ashl
```

它会首先下载 Cloudflare 的 IP 列表，然后把各个业务的配置文件拼接成一个完整的 Caddyfile。其下载过程是:

```bash
#!/bin/bash
set -e

echo "Fetching Cloudflare IP ranges..."

# Fetch IPv4 ranges
echo "Fetching IPv4 ranges from https://www.cloudflare.com/ips-v4"
IPV4_RANGES=$(curl -s https://www.cloudflare.com/ips-v4 | tr '\n' ' ')

# Fetch IPv6 ranges
echo "Fetching IPv6 ranges from https://www.cloudflare.com/ips-v6"
IPV6_RANGES=$(curl -s https://www.cloudflare.com/ips-v6 | tr '\n' ' ')

# Combine all ranges
ALL_RANGES="$IPV4_RANGES $IPV6_RANGES"

echo "Generating cloudflare_ips.conf..."

# Generate the configuration file
cat > ./cloudflare_ips.conf << EOF
# Auto-generated Cloudflare Configuration
# Generated at: $(date -u +"%Y-%m-%d %H:%M:%S UTC")

# 1. Trust proxy configuration
(cloudflare_trust) {
    trusted_proxies static $ALL_RANGES
}

# 2. Security & TLS Configuration
# This snippet handles both: certificate loading + mTLS verification
(limit_to_cloudflare) {
    tls /data/caddy/certs/anduinos.pem /data/caddy/certs/anduinos.key {
        client_auth {
            mode require_and_verify
            trust_pool file /etc/caddy/origin-pull-ca.pem
        }
    }
}
EOF

echo "✓ Cloudflare IP configuration generated successfully"
echo "  IPv4 ranges: $(echo $IPV4_RANGES | wc -w)"
echo "  IPv6 ranges: $(echo $IPV6_RANGES | wc -w)"
echo "  Total ranges: $(echo $ALL_RANGES | wc -w)"

```

上述代码会生成一个 `cloudflare_ips.conf` 文件，内容大概如下：

```caddy
# Auto-generated Cloudflare Configuration
# Generated at: 2026-01-10 16:50:43 UTC

# 1. Trust proxy configuration
(cloudflare_trust) {
    trusted_proxies static 173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22 2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32
}

# 2. Security & TLS Configuration
# This snippet handles both: certificate loading + mTLS verification
(limit_to_cloudflare) {
    tls /data/caddy/certs/anduinos.pem /data/caddy/certs/anduinos.key {
        client_auth {
            mode require_and_verify
            trust_pool file /etc/caddy/origin-pull-ca.pem
        }
    }
}
```

它的作用是之后我们在 baseline 里引用的，其中 `(limit_to_cloudflare)` 引用了两张证书：

* `/data/caddy/certs/anduinos.key`。这张证书是 Cloudflare 下发的，用来给 Caddy 作响应使用的。显然，在这里证书还是假的，真正的证书会在运行时通过 Docker Volume 分发给 Caddy。暂且不管这张证书，继续配置。
* `/etc/caddy/origin-pull-ca.pem`。这张证书是 Cloudflare 的公钥，用来验证 Cloudflare 发起请求时携带的证书是否合法。只要验证通过，Caddy 才会继续处理请求。这样就实现了 **Authenticated Origin Pulls**，即只有 Cloudflare 能访问 Caddy。

双向验证完成后，即可开启最严格的 Full Strict 模式。

之后，`/app/build_proxy.sh` 会去拼接 `baseline` 文件。baseline。baseline 文件是 Caddy 的基础配置，例如：

```caddy
{
    log {
        format json
        output file /data/caddy/logs/web.log {
            roll_size 1gb
            roll_uncompressed
        }
        level debug
    }

    servers :443 {
        import cloudflare_trust
        
        listener_wrappers {
            http_redirect
            tls
        }
    }
}

(hsts) {
    header Strict-Transport-Security max-age=63072000
}

```

其中，`cloudflare_trust` 会让 Caddy 信任 Cloudflare 的 IP 作为代理，从而正确还原真实的客户端 IP。

之后，`/app/build_proxy.sh` 会把各个业务的配置文件拼接成一个完整的 Caddyfile。业务配置例如：

```caddy
tracer.anduinos.com {
    log
    import limit_to_cloudflare
    reverse_proxy http://tracer_app:5000
}

download.anduinos.com {
    log
    import hsts
    import limit_to_cloudflare
    encode br gzip
    reverse_proxy http://download_web:5000
}

```

这些文件可能会散落到各个目录中，`/app/build_proxy.sh` 会把它们全部找到并拼接。具体来说，它会找到所有当前目录下的 `*.conf` 文件（除了 `cloudflare_ips.conf`）。

我组织这些目录的方式是：

```bash
anduin@ultra:~/Source/Repos/Anduin/bash-app/AnduinOS-Swarm$ tree
.
├── stage2
│   ├── images
│   │   └── sites
│   │       ├── baseline
│   │       ├── build_proxy.sh
│   │       ├── cloudflare_ips.conf
│   │       ├── Dockerfile
│   │       └── fetch_cloudflare_ips.sh
│   └── stacks
│       └── incoming
│           ├── docker-compose.yml
│           └── test.conf
└── stage4
    └── stacks
        ├── anduinos
        │   ├── anduinos.conf
        │   └── docker-compose.yml
        ├── clickhouse
        │   ├── clickhouse.conf
        │   ├── config_override.xml
        │   ├── docker-compose.yml
        │   └── users_override.xml
        ├── download
        │   ├── docker-compose.yml
        │   └── download.conf
        ├── grafana
        │   ├── docker-compose.yml
        │   └── grafana.conf
        ├── news
        │   ├── docker-compose.yml
        │   └── news.conf
        ├── shepherd
        │   └── docker-compose.yml
        └── tracer
            ├── docker-compose.yml
            └── tracer.conf
```

它的优势是可以将各个业务的配置文件独立开来，方便管理和维护。每次编译 `sites` 镜像时，记得写个脚本把 `stage4/stacks` 目录下的所有 `*.conf` 文件都复制到 `stage2/images/sites` 目录下即可。

```bash
rm -rf ./stage2/images/sites/discovered
mkdir -p ./stage2/images/sites/discovered && \
    cp ./stage2/stacks/**/*.conf ./stage2/images/sites/discovered && \
    cp ./stage4/stacks/**/*.conf ./stage2/images/sites/discovered
```

完全拼接完成的最终 Caddyfile 会被放到 `/app/Dist/Caddyfile`，然后被复制到最终的 Caddy 镜像中。它可能看起来像这样：

```caddy
# Auto-generated Cloudflare Configuration
# Generated at: 2026-01-10 15:13:24 UTC

# 1. Trust proxy configuration
(cloudflare_trust) {
    trusted_proxies static 173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22 2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32
}

# 2. Security & TLS Configuration
# This snippet handles both: certificate loading + mTLS verification
(limit_to_cloudflare) {
    tls /data/caddy/certs/anduinos.pem /data/caddy/certs/anduinos.key {
        client_auth {
            mode require_and_verify
            trust_pool file /etc/caddy/origin-pull-ca.pem
        }
    }
}

{
    log {
        format json
        output file /data/caddy/logs/web.log {
            roll_size 1gb
            roll_uncompressed
        }
        level debug
    }

    servers :443 {
        import cloudflare_trust
        
        listener_wrappers {
            http_redirect
            tls
        }
    }
}

(hsts) {
    header Strict-Transport-Security max-age=63072000
}

grafana.anduinos.com {
    log
    import hsts
    import limit_to_cloudflare
    encode br gzip
    reverse_proxy http://grafana_grafana:3000
}

download.anduinos.com {
    log
    import hsts
    import limit_to_cloudflare

    encode br gzip

    reverse_proxy http://download_web:5000
}

```

其中它包含三个重要部分，分别是来自 `cloudflare_ips.conf`，`baseline`，和各个业务的配置文件。

但是，它还无法工作。因为 Caddy 还没有证书。我们在上面的 Dockerfile 里生成了一个假的证书。实际工作时，我们必须把真正的 Cloudflare 证书分给 Caddy。 这一步通过 Docker Volume 来实现：

我的 `docker-compose.yml` 文件形如：

```yaml
version: '3.9'

services:
  sites:
    image: localhost:8080/box_starting/local_sites
    ports:
      # These ports are for internal use. For external, FRP will handle it.
      - target: 80
        published: 80
        protocol: tcp
        mode: host
      - target: 443
        published: 443
        protocol: tcp
        mode: host
    networks:
      - proxy_app
    volumes:
      - sites-data:/data
    stop_grace_period: 60s
    deploy:
      resources:
        limits:
          cpus: '4.0'
          memory: 16G
      update_config:
        order: stop-first
        delay: 60s

volumes:
  sites-data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /swarm-vol/sites-data

networks:
  proxy_app:
    external: true
```

其中 `/swarm-vol/sites-data` 目录结构如下：

```bash
anduin@anduinos-pl:/swarm-vol/sites-data$ tree
.
└── caddy
    ├── acme
    │   └── acme-v02.api.letsencrypt.org-directory
    │       ├── challenge_tokens
    │       └── users
    │           └── anduin@aiursoft.com
    │               ├── anduin.json
    │               └── anduin.key
    ├── certs
    │   ├── anduinos.key
    │   └── anduinos.pem
    ├── instance.uuid
    ├── last_clean.json
    ├── locks
    ├── logs  [error opening dir]
    └── ocsp

```

其中 `certs/anduinos.pem` 和 `certs/anduinos.key` 就是真正的 Cloudflare 证书。这样 Caddy 启动后，就能使用真正的证书工作了。

请将证书保护好，否则黑客拿到证书即可伪装自己是服务器向 Cloudflare 发起响应。

到这里，我们已经完成了三重配置：

* Caddy 使用Cloudflare的证书
* Caddy 每次请求都要验证 Cloudflre 的 mTLS 证书
* Caddy **只信任Cloudflare** 作为前置代理

实际业务运行是无感的，它们仍然会获得 `X-Forwarded-For` 头部的真实 IP 地址。

## 乌云

上面的配置虽然无比安全，当然有一点点乌云。其中最严重的问题就是：

* 内部的服务互相访问的时候，有的时候会去 Cloudflare 绕路。

其中最典型的就是：Authentik 等强制要求 HTTPS 的服务、Registry 等必须填写公共 Endpoint 的服务。一个数据中心往往内部流量是非常多的，例如：

* Authentik
* Registry
* GitLab Runner
* Grafana
* Prometheus
* ClickHouse

这些服务如果都通过 Cloudflare 访问，势必会增加延迟，降低性能。

但是，现在几乎不可能不绕路。因为 Caddy 强制 mTLS 验证，非 Cloudflare 的请求根本无法通过验证。因此，这是上述架构的一朵乌云。我们有一个办法，可以在稍微降低安全性的前提下，解决这个问题。

我们：

* 不再检查 mTLS
* 不再返回 Cloudflare 的证书，而是直接基于 Cloudflare 的 API Token 去申请 DNS 来验证 Let's encrypt 的证书
* 使用 IP 地址段来限制访问
* 为了加速内网访问，使用容器别名

为了完成上面几个过程，我们需要修改 `cloudflare_ips.conf` 文件，变成下面这样：

```bash
#!/bin/bash
set -e

echo "Fetching Cloudflare IP ranges..."

# Fetch IPv4 ranges
echo "Fetching IPv4 ranges from https://www.cloudflare.com/ips-v4"
IPV4_RANGES=$(curl -s https://www.cloudflare.com/ips-v4 | tr '\n' ' ')

# Fetch IPv6 ranges
echo "Fetching IPv6 ranges from https://www.cloudflare.com/ips-v6"
IPV6_RANGES=$(curl -s https://www.cloudflare.com/ips-v6 | tr '\n' ' ')

# Combine all ranges
ALL_RANGES="$IPV4_RANGES $IPV6_RANGES"

echo "Generating cloudflare_ips.conf..."

# Generate the configuration file
cat > ./cloudflare_ips.conf << EOF
# Auto-generated Cloudflare Configuration
# Generated at: $(date -u +"%Y-%m-%d %H:%M:%S UTC")

# 1. Trust proxy configuration
(cloudflare_trust) {
    trusted_proxies static $ALL_RANGES
}

# 2. IP-based Access Control
# Logic: If Request is NOT from Cloudflare AND NOT from Private Network -> Abort
(limit_to_cloudflare) {
    @denied {
        # Condition 1: IP is NOT in Cloudflare ranges
        not remote_ip $ALL_RANGES
        
        # Condition 2: IP is NOT in Docker/Local private ranges
        # (Caddy joins these lines with AND logic)
        not remote_ip private_ranges
    }
    
    # Execute abort if the request matches the @denied criteria
    abort @denied
}
EOF

echo "✓ Cloudflare IP configuration generated successfully"
echo "  IPv4 ranges: $(echo $IPV4_RANGES | wc -w)"
echo "  IPv6 ranges: $(echo $IPV6_RANGES | wc -w)"
echo "  Total ranges: $(echo $ALL_RANGES | wc -w)"
```

核心变化就是生成的 `(limit_to_cloudflare)` 片段变成了 IP 限制，而不是 mTLS 验证。

另外，也不再返回 Cloudflare 的证书，而是使用 Let's Encrypt 的 DNS-01 挑战来获取证书。

但是，显然我们的服务器在 Cloudflare 后面，几乎不可能办理下来证书。因此，我们必须使用 Cloudflare 的 API Token 来办理证书。

我们修改 baseline 文件，变成下面这样：

```
{
	# Email for Let's Encrypt notifications (certificate expiration, etc.)
	email anduin@aiursoft.com
	
	# Global ACME configuration for Let's Encrypt DNS-01 challenge
	acme_dns cloudflare {env.CLOUDFLARE_API_TOKEN}

	log {
		format json
		output file /data/caddy/logs/web.log {
			roll_size 1gb
			roll_uncompressed
		}
		level debug
	}

	servers :443 {
		import cloudflare_trust
		
		listener_wrappers {
			http_redirect
			ls
		}
	}
}

(hsts) {
	header Strict-Transport-Security max-age=63072000
}
```

它引用了插件：`acme_dns cloudflare`，并且使用环境变量 `CLOUDFLARE_API_TOKEN` 来办理证书。此 TOKEN 可以在 Cloudflare 的 Dashboard 里生成，权限只需要 DNS 编辑权限即可。

同样，我们也需要调整 Caddy 的 Dockerfile，去掉假证书的生成步骤，因为现在 Caddy 会自己办理证书。并且增加插件 `caddy-dns/cloudflare`。

```Dockerfile
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

```

这样调整后，Caddy 就能通过 Cloudflare API Token 办理证书，并且只允许 Cloudflare IP 和自己的私有网络访问。最终生成的 `cloudflare_ips.conf` 文件大概如下：

```caddy
# Auto-generated Cloudflare Configuration
# Generated at: 2026-01-11 08:34:22 UTC

# 1. Trust proxy configuration
(cloudflare_trust) {
    trusted_proxies static 173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22 2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32
}

# 2. IP-based Access Control
# Logic: If Request is NOT from Cloudflare AND NOT from Private Network -> Abort
(limit_to_cloudflare) {
    @denied {
        # Condition 1: IP is NOT in Cloudflare ranges
        not remote_ip 173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22 2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32
        
        # Condition 2: IP is NOT in Docker/Local private ranges
        # (Caddy joins these lines with AND logic)
        not remote_ip private_ranges
    }
    
    # Execute abort if the request matches the @denied criteria
    abort @denied
}

{
	# Email for Let's Encrypt notifications (certificate expiration, etc.)
	email anduin@aiursoft.com
	
	# Global ACME configuration for Let's Encrypt DNS-01 challenge
	acme_dns cloudflare {env.CLOUDFLARE_API_TOKEN}

	log {
		format json
		output file /data/caddy/logs/web.log {
			roll_size 1gb
			roll_uncompressed
		}
		level debug
	}

	servers :443 {
		import cloudflare_trust
		
		listener_wrappers {
			http_redirect
			ls
		}
	}
}

(hsts) {
	header Strict-Transport-Security max-age=63072000
}

grafana.anduinos.com {
    log
    import hsts
    import limit_to_cloudflare
    encode br gzip
    reverse_proxy http://grafana_grafana:3000
}

download.anduinos.com {
	log
	import hsts
	import limit_to_cloudflare

	encode br gzip

	reverse_proxy http://download_web:5000
}
```

最后，我们需要确保我们的业务容器在连接 Caddy 的时候，使用容器别名或者私有网络 IP 地址，而不是公共域名。这样就能避免流量绕路 Cloudflare 了。

这需要我们将 `docker-compose` 文件进行调整，例如：

```yaml
version: '3.9'

services:
  sites:
    image: localhost:8080/box_starting/local_sites
    ports:
      # These ports are for internal use. For external, FRP will handle it.
      - target: 80
        published: 80
        protocol: tcp
        mode: host
      - target: 443
        published: 443
        protocol: tcp
        mode: host
    networks:
      proxy_app:
        aliases:
          # Adding aliases for internal access to avoid Cloudflare routing
          - download.anduinos.com
          - tracer.anduinos.com
          - grafana.anduinos.com
    environment:
      # Cloudflare API token for Let's Encrypt DNS-01 challenge
      # Create token at: Cloudflare Dashboard -> My Profile -> API Tokens
      # Required permissions: Zone:DNS:Edit for target zones
      - CLOUDFLARE_API_TOKEN={{CLOUDFLARE_API_TOKEN}}
    volumes:
      - sites-data:/data
    stop_grace_period: 60s
    deploy:
      resources:
        limits:
          cpus: '4.0'
          memory: 16G
      update_config:
        order: stop-first
        delay: 60s


volumes:
  sites-data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /swarm-vol/sites-data

networks:
  proxy_app:
    external: true
  clickhouse_net:
    external: true

```

其中 `networks.proxy_app.aliases` 部分，添加了各个业务的容器别名。这样，业务容器在访问 Caddy 的时候，就会直接通过 Docker 内网访问，而不会绕路 Cloudflare 了。

最终，为了验证配置的有效性，可以去任意一个非 `caddy` 的容器里，使用 `curl` 去访问 Caddy：

```bash
apt-get update && apt-get install -y curl
curl -v https://download.anduinos.com
```

如果解析出来的 IP 地址是 Caddy 的内网 IP 地址，而不是 Cloudflare 的 IP 地址，说明配置成功。

这样配置完了以后，我们的安全性稍微有一点点下降（不再验证 mTLS），但是维护压力大幅降低。所有业务既可以去 Cloudflare 绕一圈儿，也可以直接通过内网访问 Caddy。并且黑客因为无法伪造 Cloudflare 的 IP 段，依然很难攻击到 Caddy。

当然，这样增加的安全风险，就是验证 mTLS 的功能被放弃了。这丧失了 0信任，但是转而使用了通用信任。仍然是业界标准的安全等级。

## Architecture Diagram

```mermaid
graph LR
    %% ========================================== 
    %% 1. 🎨 高级样式定义 (Premium Styles)
    %% ========================================== 
    classDef base fill:#fff,stroke:#333,stroke-width:1px,rx:5,ry:5;
    
    %% 用户 & 终端 (绿色系 - 圆角)
    classDef user fill:#e3f2fd,stroke:#2196f3,stroke-width:2px,rx:10,ry:10,color:#0d47a1;
    
    %% 云设施 (黄色系 - 云状/不对称)
    classDef cloud fill:#fff8e1,stroke:#ffc107,stroke-width:2px,rx:5,ry:5,stroke-dasharray: 2 2;
    
    %% 路由器 (青色系 - 六边形)
    classDef router fill:#e0f2f1,stroke:#009688,stroke-width:2px,color:#004d40;
    
    %% 核心网关 (紫色系 - 体育场形/胶囊形)
    classDef gateway fill:#f3e5f5,stroke:#9c27b0,stroke-width:3px,color:#4a148c,rx:20,ry:20;
    
    %% 守护进程 (灰色系 - 圆形)
    classDef process fill:#f5f5f5,stroke:#9e9e9e,stroke-width:1px,stroke-dasharray: 3 3,rx:5,ry:5;
    
    %% 业务应用 (白色 - 强边框)
    classDef app fill:#ffffff,stroke:#343a40,stroke-width:2px,rx:2,ry:2;
    
    %% DNS 逻辑节点 (橙色)
    classDef dnsnode fill:#fff3e0,stroke:#ff9800,stroke-width:2px,rx:50,ry:50;

    %% ========================================== 
    %% 2. 外部世界
    %% ========================================== 
    subgraph Ext [☁️ 外部网络 / Internet]
        direction TB
        WebUser([🟢 Web 用户]):::user
        SSHUser([🧑‍💻 SSH/MC 用户]):::user

        subgraph PublicInfra [公网基建]
            direction TB
            CF_Edge{{🛡️ Cloudflare Edge}}:::cloud
            FRPS{{🚀 FRPS 服务器}}:::cloud
        end
    end

    %% ========================================== 
    %% 3. 家庭网络 (左侧入口)
    %% ========================================== 
    subgraph Home [🏠 苏州联通家庭宽带]
        direction TB
        
        %% 路由器层
        subgraph NetLayer [物理网络层]
            direction TB
            ImmortalWrt{{⚡ ImmortalWrt 路由器}}:::router
            Local_Device([📱 家庭设备]):::user
        end

        %% ========================================== 
        %% 4. Docker Swarm (核心)
        %% ========================================== 
        subgraph Swarm [🐳 Docker Swarm ProArt]
            direction TB

            %% 内部 DNS 逻辑 (放在顶部或中间以减少交叉)
            Swarm_Resolver((🧭 Swarm DNS)):::dnsnode

            %% 网关栈
            subgraph GatewayStack [🏰 网关核心栈]
                direction TB
                Tunnel_Daemon(🚇 cloudflared 容器):::process
                FRPC(🔗 frpc):::process
                Caddy([⚡ Caddy 网关 ⚡]):::gateway
            end

            %% 业务应用
            subgraph Apps [📦 业务容器]
                direction TB
                GitLab[🦊 GitLab]:::app
                MC[🧱 Minecraft]:::app
                WebApps[🌐 Tracer / Manhours / 大量业务应用]:::app
            end
        end
    end

    %% ========================================== 
    %% 5. 流量连线 (实线 - 黑色/深色)
    %% ========================================== 

    %% A. 外网流量
    WebUser ==>|HTTPS| CF_Edge
    SSHUser ==>|TCP| FRPS
    
    CF_Edge ==>|Tunnel| Tunnel_Daemon
    FRPS ==>|穿透| FRPC

    Tunnel_Daemon ==>|HTTPS| Caddy
    FRPC -.->|TCP直连| GitLab & MC

    %% B. Caddy 分发
    Caddy ==>|反代| WebApps
    Caddy ==>|反代| GitLab

    %% C. 家庭内网流量 (关键路径)
    Local_Device == "3. HTTPS直连 (Caddy)" ==> Caddy
    Local_Device -.->|4. 2202 TCP 端口直连| GitLab
    Local_Device -.->|4. 25565 TCP 端口直连| MC

    %% ========================================== 
    %% 6. DNS 逻辑连线 (虚线 - 橙色)
    %% ========================================== 
    
    %% DNS 请求流
    Local_Device -. "1. DNS查询 *.aiursoft.com" .-> ImmortalWrt
    ImmortalWrt -. "2. 劫持返回内网IP" .-> Local_Device

    %% 容器内部降级逻辑
    WebApps -. "DNS请求" .-> Swarm_Resolver
    
    Swarm_Resolver -.->|① 命中Alias| Caddy
    Swarm_Resolver -.->|② 未命中: 问上游| ImmortalWrt
    
    ImmortalWrt -.->|③ 劫持回流| Caddy
    ImmortalWrt -.->|④ 失败: 走公网| CF_Edge

    %% ========================================== 
    %% 7. 连线样式微调 (让图看起来更干净)
    %% ========================================== 
    linkStyle default stroke:#333,stroke-width:1px;
    
    %% 高亮主要数据流 (加粗)
    linkStyle 0,1,2,3,4,7,8,9 stroke:#2196f3,stroke-width:2px;
    
    %% 高亮 Caddy 核心分发 (紫色)
    linkStyle 7,8 stroke:#9c27b0,stroke-width:3px;
    
    %% 高亮 DNS 逻辑 (橙色虚线)
    linkStyle 11,12,13,14,15,16,17 stroke:#ff9800,stroke-width:2px,stroke-dasharray: 3 3;
```
```