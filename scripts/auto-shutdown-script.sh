#!/bin/bash
# Auto-shutdown script for EC2 instance
# Monitors REAL user activity: last message via WhatsApp/Telegram/Web (OpenClaw sessions)
# Shuts down after IDLE_THRESHOLD minutes of zero prompt activity

set -e

# Configuration
IDLE_THRESHOLD=30      # minutes of inactivity before shutdown
CHECK_INTERVAL=60      # seconds between checks
LOG_FILE="/var/log/auto-shutdown.log"
LOCK_FILE="/var/run/auto-shutdown.lock"
CONFIG_FILE="/etc/auto-shutdown.conf"
ACTIVITY_MARKER="/tmp/.auto-shutdown-activity"

# OpenClaw session directory — last message across ALL channels (WhatsApp, Telegram, web)
OPENCLAW_SESSIONS_DIR="/home/bala/.openclaw/agents/main/sessions"

# Load configuration if exists
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }
info()  { log "INFO: $1"; echo -e "${GREEN}[INFO]${NC} $1" >&2; }
warn()  { log "WARN: $1"; echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
error() { log "ERROR: $1"; echo -e "${RED}[ERROR]${NC} $1" >&2; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
}

create_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            error "Auto-shutdown script already running (PID: $pid)"
            exit 1
        else
            warn "Removing stale lock file"
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"; exit' INT TERM EXIT
}

mark_activity() {
    touch "$ACTIVITY_MARKER"
}

# -------------------------------------------------------
# PRIMARY ACTIVITY CHECK: Last OpenClaw session message
# This covers WhatsApp, Telegram, web portal — all channels
# Returns epoch seconds of last message, or 0 if not found
# -------------------------------------------------------
get_last_openclaw_activity() {
    if [[ ! -d "$OPENCLAW_SESSIONS_DIR" ]]; then
        echo 0
        return
    fi

    # Most recently modified session file = latest message from any channel
    local latest_session
    latest_session=$(ls -t "$OPENCLAW_SESSIONS_DIR"/*.jsonl 2>/dev/null | head -1)

    if [[ -z "$latest_session" ]]; then
        echo 0
        return
    fi

    # Get file modification time (updated on every new message)
    stat -c %Y "$latest_session" 2>/dev/null || echo 0
}

# -------------------------------------------------------
# Get idle minutes based on last real user prompt
# -------------------------------------------------------
get_idle_time() {
    local current_time
    current_time=$(date +%s)

    # Get last OpenClaw activity (any channel: WhatsApp, Telegram, web)
    local last_openclaw
    last_openclaw=$(get_last_openclaw_activity)

    # Get activity marker time (manual touch or system activity)
    local marker_time=0
    if [[ -f "$ACTIVITY_MARKER" ]]; then
        marker_time=$(stat -c %Y "$ACTIVITY_MARKER" 2>/dev/null || echo 0)
    fi

    # Use the MOST RECENT of the two signals
    local last_activity
    if [[ "$last_openclaw" -gt "$marker_time" ]]; then
        last_activity=$last_openclaw
    else
        last_activity=$marker_time
    fi

    if [[ "$last_activity" -eq 0 ]]; then
        # No signal at all — initialize marker and treat as just-active
        mark_activity
        echo 0
        return
    fi

    local idle_seconds=$(( current_time - last_activity ))
    local idle_minutes=$(( idle_seconds / 60 ))
    echo "$idle_minutes"
}

# -------------------------------------------------------
# SECONDARY: Fallback system-level activity checks
# Used only if OpenClaw session signal is missing
# -------------------------------------------------------
check_system_activity() {
    local is_active=1  # assume idle

    # Critical services running = system in use
    if pgrep -x "node" > /dev/null 2>&1; then
        is_active=0
    fi

    # Active SSH session
    local active_sessions
    active_sessions=$(who 2>/dev/null | wc -l)
    if [[ "$active_sessions" -gt 0 ]]; then
        is_active=0
    fi

    # High load
    local load_avg
    load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//')
    if (( $(echo "$load_avg > 1.0" | bc -l 2>/dev/null || echo 0) )); then
        is_active=0
    fi

    return $is_active
}

# Check if it's business hours (7 AM - 9 PM SGT)
is_business_hours() {
    local current_hour
    current_hour=$(TZ='Asia/Singapore' date +%H)
    if [[ "$current_hour" -ge 7 && "$current_hour" -lt 21 ]]; then
        return 0
    else
        return 1
    fi
}

send_notification() {
    local message="$1"
    if command -v wall &> /dev/null; then
        echo "$message" | wall
    fi
    if command -v logger &> /dev/null; then
        logger -t auto-shutdown "$message"
    fi
}

perform_shutdown() {
    local reason="$1"
    info "Initiating shutdown: $reason"
    send_notification "System shutting down due to inactivity after $IDLE_THRESHOLD minutes"
    sleep 30
    send_notification "System shutting down now..."
    sync
    sleep 5
    log "Shutting down system"
    /sbin/shutdown -h now "Auto-shutdown: $reason"
}

monitor_system() {
    info "Starting smart auto-shutdown monitor (idle threshold: ${IDLE_THRESHOLD} min)"
    info "Activity signal: OpenClaw sessions in $OPENCLAW_SESSIONS_DIR"
    info "Monitoring: 24/7 (no business hours restriction)"

    # FIX: Touch activity marker on boot so old session file timestamps don't
    # trigger immediate shutdown. This resets the idle clock to "just started".
    mark_activity
    info "Boot grace: activity marker reset — idle clock starts now"

    local boot_time
    boot_time=$(date +%s)
    local min_uptime=$(( IDLE_THRESHOLD * 60 ))

    while true; do
        local idle_minutes
        idle_minutes=$(get_idle_time)

        # Log last activity source for debugging
        local last_openclaw
        last_openclaw=$(get_last_openclaw_activity)
        local last_openclaw_age=$(( ($(date +%s) - last_openclaw) / 60 ))

        # FIX: Boot guard — don't shutdown until machine has been up for at least
        # IDLE_THRESHOLD minutes, even if idle signal says otherwise.
        local uptime_seconds=$(( $(date +%s) - boot_time ))
        if [[ "$uptime_seconds" -lt "$min_uptime" ]]; then
            local grace_remaining=$(( (min_uptime - uptime_seconds) / 60 ))
            info "Boot grace period — ${grace_remaining}min remaining before idle checks begin"
            sleep "$CHECK_INTERVAL"
            continue
        fi

        if [[ "$idle_minutes" -ge "$IDLE_THRESHOLD" ]]; then
            warn "No user prompt for $idle_minutes min (last OpenClaw msg: ${last_openclaw_age}min ago)"
            warn "Shutdown threshold: $IDLE_THRESHOLD min — shutting down"
            perform_shutdown "No user activity for $idle_minutes minutes"
            break
        else
            local remaining=$(( IDLE_THRESHOLD - idle_minutes ))
            info "Active — last prompt ${idle_minutes}min ago (shutdown in ${remaining}min if no activity)"
        fi

        sleep "$CHECK_INTERVAL"
    done
}

install_service() {
    info "Installing smart auto-shutdown service..."
    cp "$0" /usr/local/bin/auto-shutdown
    chmod +x /usr/local/bin/auto-shutdown

    cat > /etc/systemd/system/auto-shutdown.service << 'EOF'
[Unit]
Description=Auto-shutdown monitoring service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/auto-shutdown monitor
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    if [[ ! -f "$CONFIG_FILE" ]]; then
        cat > "$CONFIG_FILE" << EOF
# Auto-shutdown configuration
IDLE_THRESHOLD=30     # minutes since last WhatsApp/Telegram/web prompt before shutdown
CHECK_INTERVAL=60     # seconds between idle checks
EOF
    fi

    systemctl daemon-reload
    systemctl enable auto-shutdown.service
    systemctl restart auto-shutdown.service

    info "Smart auto-shutdown service installed"
    info "Activity signal: most recently modified OpenClaw session file"
    info "Channels covered: WhatsApp, Telegram, Web portal"
}

uninstall_service() {
    systemctl stop auto-shutdown.service 2>/dev/null || true
    systemctl disable auto-shutdown.service 2>/dev/null || true
    rm -f /etc/systemd/system/auto-shutdown.service
    rm -f /usr/local/bin/auto-shutdown
    rm -f "$LOCK_FILE"
    systemctl daemon-reload
    info "Auto-shutdown service uninstalled"
}

show_status() {
    echo "Smart Auto-shutdown Monitor Status"
    echo "==================================="
    echo "Config: idle=${IDLE_THRESHOLD}min, check=${CHECK_INTERVAL}s"
    echo ""

    local last_openclaw
    last_openclaw=$(get_last_openclaw_activity)
    local last_openclaw_age=$(( ($(date +%s) - last_openclaw) / 60 ))
    local idle_minutes
    idle_minutes=$(get_idle_time)

    echo "Activity signals:"
    echo "  Last OpenClaw session update: ${last_openclaw_age} min ago"
    if [[ -f "$ACTIVITY_MARKER" ]]; then
        local marker_age=$(( ($(date +%s) - $(stat -c %Y "$ACTIVITY_MARKER")) / 60 ))
        echo "  Activity marker: ${marker_age} min ago"
    fi
    echo "  → Effective idle time: ${idle_minutes} min"
    echo "  → Shutdown in: $(( IDLE_THRESHOLD - idle_minutes )) min (if no activity)"
    echo ""
    echo "Context:"
    echo "  Monitoring: 24/7 (always active)"
    echo "  Current SGT: $(TZ='Asia/Singapore' date '+%H:%M')"

    if [[ -f "$LOCK_FILE" ]]; then
        local pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if kill -0 "$pid" 2>/dev/null; then
            echo "  Service: RUNNING (PID: $pid)"
        else
            echo "  Service: STOPPED (stale lock)"
        fi
    else
        echo "  Service: STOPPED"
    fi
}

case "${1:-}" in
    monitor)    check_root; create_lock; monitor_system ;;
    install)    check_root; install_service ;;
    uninstall)  check_root; uninstall_service ;;
    status)     show_status ;;
    activity)   mark_activity; echo "Activity marked — idle timer reset" ;;
    *)
        echo "Usage: $0 {monitor|install|uninstall|status|activity}"
        echo ""
        echo "Activity signal: last modified OpenClaw session file"
        echo "Covers: WhatsApp, Telegram, Web portal — any prompt resets the 30min clock"
        exit 1
        ;;
esac
