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