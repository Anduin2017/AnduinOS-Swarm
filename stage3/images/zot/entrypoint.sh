#!/bin/sh
set -e

# 确保挂载点存在
mkdir -p /config /etc/zot /data

# 处理 config.json：有就用它，没就复制默认的并软链
SRC_SETTINGS="/etc/zot/config.json"
VOL_SETTINGS="/config/config.json"
if [ ! -f "$VOL_SETTINGS" ]; then
    cp $SRC_SETTINGS $VOL_SETTINGS
fi
if [ -f "$SRC_SETTINGS" ]; then
    rm $SRC_SETTINGS
fi
ln -s $VOL_SETTINGS $SRC_SETTINGS

# 启动 zot（以 root 直接跑）
exec /usr/local/bin/zot serve /etc/zot/config.json
