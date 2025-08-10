FROM localhost:8080/public_mirror/ubuntu:25.04

COPY source.list /suggested.sources.list

RUN apt update && apt install -y curl

RUN if curl -f http://mirror.aiursoft.cn; then \
        echo "Using mirror.aiursoft.cn" && \
        cp /suggested.sources.list /etc/apt/sources.list && \
        apt update; \
    fi

RUN apt upgrade -y
