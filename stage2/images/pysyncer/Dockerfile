# ===========================
# Build/Runtime in one stage
# ===========================
FROM localhost:8080/box_starting/local_ubuntu 

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_BREAK_SYSTEM_PACKAGES=1

# 必要包：clickhouse-connect 做写入；tzdata 提供时区；watchdog/uvloop 可选
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates tzdata python3 python-is-python3 python3-pip \
        build-essential python3-dev \
    && rm -rf /var/lib/apt/lists/*

RUN pip install clickhouse-connect==0.8.18 uvloop==0.21.0 watchdog==6.0.0

WORKDIR /app
COPY main.py /app/main.py

# 默认环境变量（可在 compose/Swarm 覆盖）
ENV LOG_FILE=/data/caddy/logs/web.log \
    CLICKHOUSE_URL=http://clickhouse:8123 \
    CLICKHOUSE_USER=default \
    CLICKHOUSE_PASSWORD=123456 \
    CLICKHOUSE_DATABASE=logs \
    CLICKHOUSE_TABLE=caddy_requests \
    BATCH_SIZE=1000 \
    FLUSH_INTERVAL_SEC=2 \
    TZ="UTC"

CMD ["python", "/app/main.py"]
