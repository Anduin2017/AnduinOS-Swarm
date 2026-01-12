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
    trusted_proxies static $ALL_RANGES private_ranges
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
