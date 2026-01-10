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
# Auto-generated Cloudflare IP configuration
# Generated at: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
# Source: https://www.cloudflare.com/ips-v4 and https://www.cloudflare.com/ips-v6

# Define cloudflare_ip_ranges snippet for trusted_proxies
(cloudflare_ip_ranges) {
	trusted_proxies static $ALL_RANGES
}

# Define limit_to_cloudflare snippet for access control
(limit_to_cloudflare) {
	@denied {
		not remote_ip $ALL_RANGES
	}
	abort @denied
}
EOF

echo "✓ Cloudflare IP configuration generated successfully"
echo "  IPv4 ranges: $(echo $IPV4_RANGES | wc -w)"
echo "  IPv6 ranges: $(echo $IPV6_RANGES | wc -w)"
echo "  Total ranges: $(echo $ALL_RANGES | wc -w)"
