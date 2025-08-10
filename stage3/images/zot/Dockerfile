# The version need to be updated regularly.
ARG ZOT_VERSION=v2.1.7
FROM localhost:8080/box_starting/local_ubuntu

ARG ZOT_VERSION
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends wget ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /etc/zot /config /data

RUN wget -O /usr/local/bin/zot "https://git.aiursoft.cn/PublicVault/zot/releases/download/${ZOT_VERSION}/zot-linux-amd64" \
    && chmod +x /usr/local/bin/zot

COPY default-config.json /etc/zot/default-config.json
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 5000

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
