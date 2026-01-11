#!/bin/bash
set -e

echo "Generating docker-compose.yml with auto-discovered domains..."

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Extract domains from all .conf files (excluding cloudflare_ips.conf)
echo "Scanning for .conf files in stage2/stacks and stage4/stacks..."
DOMAINS=$(grep -hE "^[a-zA-Z0-9.-]+\.[a-zA-Z]+ \{" \
    "$REPO_ROOT"/stage2/stacks/**/*.conf \
    "$REPO_ROOT"/stage4/stacks/**/*.conf \
    2>/dev/null | sed 's/ {.*//' | sort -u)

# Check if any domains were found
if [ -z "$DOMAINS" ]; then
    echo "⚠️  Warning: No domains found in .conf files!"
    exit 1
fi

echo "Found domains:"
echo "$DOMAINS" | sed 's/^/  - /'

# Generate the domain aliases section with proper YAML indentation
DOMAIN_LIST=""
while IFS= read -r domain; do
    DOMAIN_LIST="${DOMAIN_LIST}          - ${domain}
"
done <<< "$DOMAINS"

# Remove the trailing newline
DOMAIN_LIST="${DOMAIN_LIST%$'\n'}"

# Read the template file
TEMPLATE_FILE="$SCRIPT_DIR/docker-compose.template.yml"
if [ ! -f "$TEMPLATE_FILE" ]; then
    echo "❌ Error: Template file not found: $TEMPLATE_FILE"
    exit 1
fi

# Create output file by replacing placeholders line by line
OUTPUT_FILE="$SCRIPT_DIR/docker-compose.yml"
rm -f "$OUTPUT_FILE"

while IFS= read -r line; do
    if [[ "$line" == *"---DOMAINS---"* ]]; then
        # Replace ---DOMAINS--- with the actual domain list
        echo "$DOMAIN_LIST" >> "$OUTPUT_FILE"
    else
        echo "$line" >> "$OUTPUT_FILE"
    fi
done < "$TEMPLATE_FILE"

echo "✓ Generated: $OUTPUT_FILE"
echo ""
echo "📋 Summary:"
echo "  - Discovered $(echo "$DOMAINS" | wc -l) unique domains"
echo "  - Output: $OUTPUT_FILE"
echo ""
echo "💡 To deploy:"
echo "   docker stack deploy -c $OUTPUT_FILE incoming"
