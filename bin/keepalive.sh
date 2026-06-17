#!/bin/bash

# Keepalive script for VPN connections
# Usage: keepalive.sh <type> <target> <interval> <vpn_name> <debug> <pid_file>

TYPE=$1
TARGET=$2
INTERVAL=$3
VPNNAME=$4
DEBUG=$5
PID_FILE=$6

LOG_DIR="../data/logs"
LOG_FILE="${LOG_DIR}/${VPNNAME}_keepalive_${TARGET}.log"

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"

log_message() {
    if [ "$DEBUG" = "true" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    fi
}

# Read and remember the VPN PID at startup (don't re-read on each iteration)
# This prevents old keepalive processes from continuing after VPN restart
if [ -f "$PID_FILE" ]; then
    VPN_PID=$(cat "$PID_FILE" 2>/dev/null)
    if [ -z "$VPN_PID" ]; then
        log_message "Error: Could not read VPN PID from $PID_FILE"
        exit 1
    fi
else
    log_message "Error: PID file $PID_FILE does not exist"
    exit 1
fi

# Check if VPN process is still running (using the remembered PID)
is_vpn_running() {
    if [ -n "$VPN_PID" ] && kill -0 "$VPN_PID" 2>/dev/null; then
        return 0  # VPN is running
    fi
    return 1  # VPN is not running
}

log_message "Keepalive started: type=$TYPE, target=$TARGET, interval=${INTERVAL}s, watching PID=$VPN_PID"

# Main keepalive loop
while true; do
    # Check if VPN is still running
    if ! is_vpn_running; then
        log_message "VPN process (PID $VPN_PID) no longer running, stopping keepalive"
        exit 0
    fi

    if [ "$TYPE" = "ping" ]; then
        if [ "$DEBUG" = "true" ]; then
            ping -c 1 "$TARGET" >> "$LOG_FILE" 2>&1
            PING_RESULT=$?
            if [ $PING_RESULT -eq 0 ]; then
                log_message "Ping to $TARGET: SUCCESS"
            else
                log_message "Ping to $TARGET: FAILED (exit code: $PING_RESULT)"
            fi
        else
            # Silent ping when debug is off
            ping -c 1 "$TARGET" > /dev/null 2>&1
        fi
    fi
    
    sleep "$INTERVAL"
done
