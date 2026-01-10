#!/usr/bin/env python3
import os
import json
import time
import signal
import errno
import threading
import asyncio
from datetime import datetime, timezone
from zoneinfo import ZoneInfo
import logging

import uvloop
from clickhouse_connect import get_client

# === Logging setup ===
logging.basicConfig(level=logging.DEBUG, format='[%(levelname)s] %(asctime)s %(message)s')
logger = logging.getLogger(__name__)

# === Configuration ===
LOG_FILE = os.getenv('LOG_FILE', '/data/caddy/logs/web.log')
CH_URL = os.getenv('CLICKHOUSE_URL', 'http://clickhouse:8123')
CH_USER = os.getenv('CLICKHOUSE_USER', 'default')
CH_PASS = os.getenv('CLICKHOUSE_PASSWORD', '')
CH_DB = os.getenv('CLICKHOUSE_DATABASE', 'logs')
CH_TABLE = os.getenv('CLICKHOUSE_TABLE', 'caddy_requests')
BATCH_SIZE = int(os.getenv('BATCH_SIZE', '1000'))
FLUSH_INTERVAL = float(os.getenv('FLUSH_INTERVAL_SEC', '2'))
TZ = ZoneInfo(os.getenv('TZ', 'UTC'))

# Columns in ClickHouse order
COLUMNS = [
    'ts', 'level', 'logger', 'msg',
    'remote_ip', 'remote_port', 'method', 'host', 'uri',
    'status', 'duration_ms', 'bytes_sent',
    'user_agent', 'country', 'err_id', 'err_trace'
]

# Shutdown event
stop_event = threading.Event()


def create_ch_client():
    secure = CH_URL.startswith('https')
    parts = CH_URL.split('://')[-1].split(':')
    host = parts[0]
    port = int(parts[1]) if len(parts) > 1 else 8123
    logger.debug("Creating ClickHouse client to %s:%d (secure=%s)", host, port, secure)
    return get_client(host=host, port=port, username=CH_USER, password=CH_PASS, database=CH_DB, secure=secure)


def get_last_timestamp():
    client = create_ch_client()
    q = f"SELECT max(ts) FROM {CH_DB}.{CH_TABLE}"
    logger.debug("Querying last timestamp with: %s", q)
    res = client.query(q)
    rows = getattr(res, 'result_rows', None)
    if rows and rows[0][0] is not None:
        val = rows[0][0]
        try:
            ts = val.timestamp() if hasattr(val, 'timestamp') else float(val)
            logger.info("Last timestamp in ClickHouse: %s", ts)
            return ts
        except Exception as e:
            logger.error("Failed to parse max(ts) result '%s': %s", val, e)
    logger.info("No existing timestamp found, starting from 0")
    return 0.0


def find_start_offset(path, last_ts):
    logger.debug("Finding start offset in %s for ts > %s", path, last_ts)
    with open(path, 'r', encoding='utf-8', errors='ignore') as f:
        f.seek(0, os.SEEK_END)
        file_size = f.tell()
        low, high, best = 0, file_size, 0
        while low < high:
            mid = (low + high) // 2
            f.seek(mid, os.SEEK_SET)
            f.readline()  # skip partial
            pos = f.tell()
            line = f.readline()
            if not line:
                high = mid
                continue
            try:
                rec = json.loads(line)
                ts_val = float(rec.get('ts', 0.0))
            except Exception:
                low = pos + len(line)
                continue
            if ts_val <= last_ts:
                best = pos + len(line)
                low = best
            else:
                high = mid
        logger.info("Determined start offset: %d", best)
        return best


def to_datetime(ts_float):
    dt_utc = datetime.fromtimestamp(ts_float, tz=timezone.utc)
    return dt_utc.astimezone(TZ)


def extract_first(hdrs, key):
    v = hdrs.get(key)
    if isinstance(v, list):
        return v[0]
    if isinstance(v, str):
        return v
    return ''


def transform(rec):
    logger.debug("Transforming record with ts=%s, logger=%s", rec.get('ts'), rec.get('logger'))
    request = rec.get('request', {}) or {}
    headers = request.get('headers', {}) or {}
    try:
        ts_dt = to_datetime(float(rec.get('ts', 0.0)))
    except Exception:
        ts_dt = datetime.now(TZ)
    duration = rec.get('duration')
    duration_ms = float(duration) * 1000.0 if duration is not None else float(rec.get('duration_ms', 0))
    row = (
        ts_dt,
        str(rec.get('level', '')),
        str(rec.get('logger', '')),
        str(rec.get('msg', '')),
        # Prioritize client_ip (real IP resolved by trusted_proxies) over remote_ip (Cloudflare node IP)
        str(request.get('client_ip') or request.get('remote_ip', '')),
        int(request.get('remote_port', 0) or 0),
        str(request.get('method', '')),
        str(request.get('host', '')),
        str(request.get('uri', '')),
        int(rec.get('status', 0) or 0),
        float(duration_ms),
        int(rec.get('size', rec.get('bytes_sent', 0)) or 0),
        str(extract_first(headers, 'User-Agent')),
        str(extract_first(headers, 'Cf-Ipcountry')),  # Country code from Cloudflare
        str(rec.get('err_id', '')),
        str(rec.get('err_trace', ''))
    )
    logger.debug("Transformed row: %s", row)
    return row


async def flusher(queue):
    client = create_ch_client()
    batch, last_flush = [], time.time()
    while not stop_event.is_set():
        try:
            item = await asyncio.wait_for(queue.get(), timeout=FLUSH_INTERVAL)
            batch.append(item)
            logger.debug("Queued batch size: %d", len(batch))
        except asyncio.TimeoutError:
            pass
        now = time.time()
        if batch and (len(batch) >= BATCH_SIZE or now - last_flush >= FLUSH_INTERVAL):
            try:
                logger.info("Flushing %d rows to ClickHouse", len(batch))
                client.insert(CH_TABLE, batch, column_names=COLUMNS)
            except Exception as e:
                logger.error("Insert failed: %s", e)
            else:
                batch.clear()
                last_flush = now
    if batch:
        try:
            logger.info("Final flush of %d rows", len(batch))
            client.insert(CH_TABLE, batch, column_names=COLUMNS)
        except Exception as e:
            logger.error("Final insert failed: %s", e)


async def reader(queue):
    last_ts = get_last_timestamp()
    logger.info("Starting reader loop")
    start_offset = find_start_offset(LOG_FILE, last_ts)
    f = open(LOG_FILE, 'r', encoding='utf-8', errors='ignore')
    inode = os.fstat(f.fileno()).st_ino
    f.seek(start_offset)
    while not stop_event.is_set():
        line = f.readline()
        if not line:
            try:
                st = os.stat(LOG_FILE)
            except OSError as e:
                if e.errno == errno.ENOENT:
                    await asyncio.sleep(0.5)
                    continue
                else:
                    raise
            if st.st_ino != inode:
                logger.info("Detected log rotation, recalculating start offset")
                f.close()
                start_offset = find_start_offset(LOG_FILE, last_ts)
                f = open(LOG_FILE, 'r', encoding='utf-8', errors='ignore')
                inode = os.fstat(f.fileno()).st_ino
                f.seek(start_offset)
                continue
            await asyncio.sleep(0.2)
            continue
        try:
            rec = json.loads(line)
        except Exception as e:
            logger.warning("Failed to parse JSON line: %s", e)
            continue
        if rec.get('logger') != 'http.log.access':
            continue
        try:
            row = transform(rec)
        except Exception as e:
            logger.error("Transform error: %s", e)
            continue
        await queue.put(row)
        logger.debug("Row queued, timestamp=%s", row[0])


def handle_signal(signum, frame):
    logger.info("Received signal %d, shutting down", signum)
    stop_event.set()


def main():
    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)
    uvloop.install()
    loop = asyncio.get_event_loop()
    queue = asyncio.Queue(maxsize=50000)
    tasks = [
        loop.create_task(reader(queue)),
        loop.create_task(flusher(queue)),
    ]
    try:
        loop.run_until_complete(asyncio.gather(*tasks))
    finally:
        for t in tasks:
            t.cancel()
        loop.stop()
        loop.close()


if __name__ == '__main__':
    main()
