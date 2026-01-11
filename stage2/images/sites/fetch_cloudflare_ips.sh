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
# Allow traffic from Cloudflare IPs and Docker internal networks only
(limit_to_cloudflare) {
	@allowed_traffic {
		remote_ip $ALL_RANGES
		remote_ip private_ranges
	}
	
	abort not @allowed_traffic
}
EOF

echo "✓ Cloudflare IP configuration generated successfully"
echo "  IPv4 ranges: $(echo $IPV4_RANGES | wc -w)"
echo "  IPv6 ranges: $(echo $IPV6_RANGES | wc -w)"
echo "  Total ranges: $(echo $ALL_RANGES | wc -w)"
