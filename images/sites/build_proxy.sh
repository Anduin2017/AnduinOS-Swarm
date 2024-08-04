#!/bin/bash
set -e

echo "Building Caddyfile at $(pwd)..."
mkdir -p ./Dist

echo "Building sites under $(pwd)..."
find . -type f -name "*.conf" | while read -r file; do cat "$file"; echo -e "\n\n"; done | tee ./Dist/Sites.temp > /dev/null

echo "Appending baseline..."
cat ./baseline ./Dist/Sites.temp | tee ./Dist/Caddyfile > /dev/null

echo "Caddyfile built."
ls ./Dist/ -ashl