#!/bin/bash
# Auto-shutdown script for EC2 instance
# Monitors system idle time and shuts down after 30 minutes of inactivity
# To be installed on the EC2 instance

set -e

# Configuration
IDLE_THRESHOLD=30  # minutes
CHECK_INTERVAL=60  # seconds between checks
LOG_FILE="/var/log/auto-shutdown.log"
LOCK_FILE="/var/run/auto-shutdown.lock"
CONFIG_FILE="/etc/auto-shutdown.conf"
ACTIVITY_MARKER="/tmp/.auto-shutdown-activity"

# Load configuration if exists
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

info() { 
    log "INFO: $1"
    echo -e "${GREEN}[INFO]${NC} $1" >&2
}

warn() { 
    log "WARN: $1"
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

error() { 
    log "ERROR: $1"
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
}

# Create lock file to prevent multiple instances
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

# Mark system as active (touch the activity marker file)
mark_activity() {
    touch "$ACTIVITY_MARKER"
}

# Check if system has activity (returns 0 if active, 1 if idle)
check_system_activity() {
    local is_active=1  # assume idle

    # Method 1: Check system load
    local load_avg
    load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//')
    if (( $(echo "$load_avg > 0.5" | bc -l 2>/dev/null || echo 0) )); then
        is_active=0
    fi

    # Method 2: Check network connections
    local active_connections
    active_connections=$(netstat -an 2>/dev/null | grep ESTABLISHED | wc -l)
    if [[ "$active_connections" -gt 5 ]]; then
        is_active=0
    fi

    # Method 3: Check running user processes (exclude system processes)
    local user_processes
    user_processes=$(ps aux | grep -v "^\(root\|daemon\|sys\|adm\)" | grep -v "\[.*\]" | wc -l)
    if [[ "$user_processes" -gt 10 ]]; then
        is_active=0
    fi

    # Method 4: Check disk I/O activity
    if command -v iostat &> /dev/null; then
        local disk_activity
        disk_activity=$(iostat -d 1 2 2>/dev/null | tail -1 | awk '{sum=$4+$5} END {print sum}' || echo 0)
        if (( $(echo "$disk_activity > 10" | bc -l 2>/dev/null || echo 0) )); then
            is_active=0
        fi
    fi

    # Method 5: Check for recent SSH sessions (within last 5 minutes)
    local recent_login
    recent_login=$(last -n 1 -R 2>/dev/null | grep -v "wtmp begins" | head -1 | grep "still logged in" | wc -l)
    if [[ "$recent_login" -gt 0 ]]; then
        is_active=0
    fi

    # Method 6: Check for active TTY/PTY sessions
    local active_sessions
    active_sessions=$(who 2>/dev/null | wc -l)
    if [[ "$active_sessions" -gt 0 ]]; then
        is_active=0
    fi

    return $is_active
}

# Get system idle time in minutes (based on activity marker file)
get_idle_time() {
    # Initialize activity marker if it doesn't exist
    if [[ ! -f "$ACTIVITY_MARKER" ]]; then
        mark_activity
    fi

    # Check for current activity - if active, update marker
    if check_system_activity; then
        mark_activity
    fi

    # Calculate idle time from marker file modification time
    local marker_mtime
    marker_mtime=$(stat -c %Y "$ACTIVITY_MARKER" 2>/dev/null || stat -f %m "$ACTIVITY_MARKER" 2>/dev/null || echo 0)

    if [[ "$marker_mtime" == "0" ]]; then
        echo "0"
        return
    fi

    local current_time
    current_time=$(date +%s)
    local idle_seconds=$((current_time - marker_mtime))
    local idle_minutes=$((idle_seconds / 60))

    echo "$idle_minutes"
}

# Check if it's business hours (7 AM - 9 PM SGT)
is_business_hours() {
    local current_hour
    current_hour=$(TZ='Asia/Singapore' date +%H)
    
    if [[ "$current_hour" -ge 7 && "$current_hour" -lt 21 ]]; then
        return 0  # true
    else
        return 1  # false
    fi
}

# Send notification before shutdown
send_notification() {
    local message="$1"
    
    # Try to notify all logged-in users
    if command -v wall &> /dev/null; then
        echo "$message" | wall
    fi
    
    # Try to send to syslog
    if command -v logger &> /dev/null; then
        logger -t auto-shutdown "$message"
    fi
    
    # If AWS CLI is available, try to send to CloudWatch
    if command -v aws &> /dev/null; then
        aws logs put-log-events \
            --log-group-name "/aws/ec2/auto-shutdown" \
            --log-stream-name "$(hostname)" \
            --log-events "timestamp=$(date +%s000),message=$message" \
            2>/dev/null || true
    fi
}

# Graceful shutdown
perform_shutdown() {
    local reason="$1"
    
    info "Initiating shutdown: $reason"
    send_notification "System shutting down due to inactivity after $IDLE_THRESHOLD minutes"
    
    # Give users time to react
    sleep 30
    
    # Final notification
    send_notification "System shutting down now..."
    
    # Sync filesystems and shutdown
    sync
    sleep 5
    
    log "Shutting down system"
    /sbin/shutdown -h now "Auto-shutdown: $reason"
}

# Main monitoring loop
monitor_system() {
    info "Starting auto-shutdown monitor (idle threshold: ${IDLE_THRESHOLD} minutes)"
    
    local consecutive_idle_checks=0
    local required_idle_checks=$((IDLE_THRESHOLD * 60 / CHECK_INTERVAL))
    
    while true; do
        # Skip monitoring during non-business hours
        if ! is_business_hours; then
            info "Outside business hours - skipping idle check"
            consecutive_idle_checks=0
            sleep "$CHECK_INTERVAL"
            continue
        fi
        
        local idle_minutes
        idle_minutes=$(get_idle_time)
        
        if [[ "$idle_minutes" -ge "$IDLE_THRESHOLD" ]]; then
            consecutive_idle_checks=$((consecutive_idle_checks + 1))
            warn "System idle for $idle_minutes minutes (check $consecutive_idle_checks/$required_idle_checks)"

            if [[ "$consecutive_idle_checks" -ge "$required_idle_checks" ]]; then
                perform_shutdown "System idle for $idle_minutes minutes"
                break
            fi
        else
            if [[ "$consecutive_idle_checks" -gt 0 ]]; then
                info "System activity detected - resetting idle counter (was idle for $idle_minutes min)"
            fi
            consecutive_idle_checks=0
            # Activity detected - marker already updated by get_idle_time()
        fi
        
        sleep "$CHECK_INTERVAL"
    done
}

# Installation function
install_service() {
    info "Installing auto-shutdown service..."
    
    # Copy script to system location
    cp "$0" /usr/local/bin/auto-shutdown
    chmod +x /usr/local/bin/auto-shutdown
    
    # Create systemd service
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
    
    # Create default configuration
    if [[ ! -f "$CONFIG_FILE" ]]; then
        cat > "$CONFIG_FILE" << EOF
# Auto-shutdown configuration
IDLE_THRESHOLD=30     # minutes of inactivity before shutdown
CHECK_INTERVAL=60     # seconds between idle checks
EOF
    fi
    
    # Enable and start service
    systemctl daemon-reload
    systemctl enable auto-shutdown.service
    systemctl start auto-shutdown.service
    
    info "Auto-shutdown service installed and started"
    info "Configuration file: $CONFIG_FILE"
    info "Log file: $LOG_FILE"
    info "Service status: systemctl status auto-shutdown"
}

# Uninstallation function
uninstall_service() {
    info "Uninstalling auto-shutdown service..."
    
    systemctl stop auto-shutdown.service 2>/dev/null || true
    systemctl disable auto-shutdown.service 2>/dev/null || true
    
    rm -f /etc/systemd/system/auto-shutdown.service
    rm -f /usr/local/bin/auto-shutdown
    rm -f "$LOCK_FILE"
    
    systemctl daemon-reload
    
    info "Auto-shutdown service uninstalled"
}

# Status function
show_status() {
    echo "Auto-shutdown Monitor Status"
    echo "============================"
    echo "Configuration:"
    echo "  Idle threshold: ${IDLE_THRESHOLD} minutes"
    echo "  Check interval: ${CHECK_INTERVAL} seconds"
    echo "  Log file: ${LOG_FILE}"
    echo ""
    
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            echo "Service status: RUNNING (PID: $pid)"
        else
            echo "Service status: STOPPED (stale lock file)"
        fi
    else
        echo "Service status: STOPPED"
    fi
    
    echo ""
    echo "Current system info:"
    echo "  Current time: $(date)"
    echo "  Business hours: $(is_business_hours && echo 'YES' || echo 'NO')"
    echo "  System active: $(check_system_activity && echo 'YES' || echo 'NO')"
    echo "  System idle: $(get_idle_time) minutes"
    echo "  Load average: $(uptime | awk -F'load average:' '{print $2}')"
    if [[ -f "$ACTIVITY_MARKER" ]]; then
        echo "  Activity marker: $(stat -c '%y' "$ACTIVITY_MARKER" 2>/dev/null || stat -f '%Sm' "$ACTIVITY_MARKER" 2>/dev/null)"
    else
        echo "  Activity marker: not created yet"
    fi
    
    if command -v systemctl &> /dev/null; then
        echo ""
        echo "Systemd service status:"
        systemctl status auto-shutdown.service --no-pager || true
    fi
}

# Usage information
usage() {
    echo "Usage: $0 {monitor|install|uninstall|status|test|activity}"
    echo ""
    echo "Commands:"
    echo "  monitor    - Start monitoring system for idle time"
    echo "  install    - Install as systemd service"
    echo "  uninstall  - Remove systemd service"
    echo "  status     - Show current status"
    echo "  test       - Test idle detection"
    echo "  activity   - Mark system as active (reset idle timer)"
    echo ""
    echo "Configuration file: $CONFIG_FILE"
    echo "Log file: $LOG_FILE"
    echo "Activity marker: $ACTIVITY_MARKER"
    exit 1
}

# Main script logic
case "${1:-}" in
    monitor)
        check_root
        create_lock
        monitor_system
        ;;
    install)
        check_root
        install_service
        ;;
    uninstall)
        check_root
        uninstall_service
        ;;
    status)
        show_status
        ;;
    test)
        echo "Testing idle detection..."
        echo "============================"
        echo "Activity marker: $ACTIVITY_MARKER"
        if [[ -f "$ACTIVITY_MARKER" ]]; then
            echo "Marker exists: YES (last modified: $(stat -c '%y' "$ACTIVITY_MARKER" 2>/dev/null || stat -f '%Sm' "$ACTIVITY_MARKER" 2>/dev/null))"
        else
            echo "Marker exists: NO (will be created)"
        fi
        echo ""
        echo "Activity checks:"
        echo "  - Load avg > 0.5: $(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//')"
        echo "  - Network connections: $(netstat -an 2>/dev/null | grep ESTABLISHED | wc -l)"
        echo "  - User processes: $(ps aux | grep -v "^\(root\|daemon\|sys\|adm\)" | grep -v "\[.*\]" | wc -l)"
        echo "  - Active sessions: $(who 2>/dev/null | wc -l)"
        echo ""
        echo "System active: $(check_system_activity && echo 'YES' || echo 'NO')"
        echo "Current idle time: $(get_idle_time) minutes"
        echo "Business hours: $(is_business_hours && echo 'YES' || echo 'NO')"
        ;;
    activity)
        mark_activity
        echo "Activity marked at $(date)"
        echo "Idle timer reset to 0"
        ;;
    *)
        usage
        ;;
esac

