#!/bin/bash
# ─────────────────────────────────────────────────────────
# DuckDNS Auto-Update Setup for Existing EC2 Instance
# Run this on the instance: sudo bash setup-duckdns.sh
# ─────────────────────────────────────────────────────────
set -e

DUCKDNS_DOMAIN="baladengale"
DUCKDNS_TOKEN="ff63fdcb-28df-42f0-9c88-7776fac4bfca"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Must run as root
if [[ $EUID -ne 0 ]]; then
    error "Run as root: sudo bash $0"
    exit 1
fi

info "Creating DuckDNS update script..."
cat > /usr/local/bin/update-duckdns.sh << 'EOF'
#!/bin/bash
# DuckDNS Dynamic DNS Updater
# Fetches public IP from EC2 Instance Metadata Service (IMDSv2) and updates DuckDNS

DUCKDNS_DOMAIN="__DUCKDNS_DOMAIN__"
DUCKDNS_TOKEN="__DUCKDNS_TOKEN__"
LOG_FILE="/var/log/duckdns-update.log"

# Wait for network and metadata service
sleep 10

# Get public IP from EC2 Instance Metadata Service (IMDSv2)
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null)
PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null)

if [[ -z "$PUBLIC_IP" || "$PUBLIC_IP" == *"Not Found"* ]]; then
    echo "$(date): ERROR - Could not retrieve public IP from IMDS" >> "$LOG_FILE"
    exit 1
fi

# Update DuckDNS
RESULT=$(curl -s "https://www.duckdns.org/update?domains=${DUCKDNS_DOMAIN}&token=${DUCKDNS_TOKEN}&ip=${PUBLIC_IP}")
echo "$(date): IP=${PUBLIC_IP} Result=${RESULT}" >> "$LOG_FILE"
EOF

# Replace placeholders
sed -i "s|__DUCKDNS_DOMAIN__|${DUCKDNS_DOMAIN}|g" /usr/local/bin/update-duckdns.sh
sed -i "s|__DUCKDNS_TOKEN__|${DUCKDNS_TOKEN}|g" /usr/local/bin/update-duckdns.sh
chmod +x /usr/local/bin/update-duckdns.sh

info "Creating systemd service for boot-time DNS update..."
cat > /etc/systemd/system/duckdns-update.service << 'EOF'
[Unit]
Description=Update DuckDNS with current public IP
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-duckdns.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

info "Enabling and starting service..."
systemctl daemon-reload
systemctl enable duckdns-update.service
systemctl start duckdns-update.service

info "Checking result..."
sleep 12
if [[ -f /var/log/duckdns-update.log ]]; then
    tail -1 /var/log/duckdns-update.log
fi

info "Done! ${DUCKDNS_DOMAIN}.duckdns.org will auto-update on every boot."
info "Verify: nslookup ${DUCKDNS_DOMAIN}.duckdns.org"
info "Logs:   cat /var/log/duckdns-update.log"

