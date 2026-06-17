#!/bin/bash
# Watches a VPN process and runs cleanup when it dies unexpectedly.
#
# Covers every exit that bypasses cmd_stop:
#   - SIGKILL / OOM kill      (vpnc-script/updown disconnect hook never runs)
#   - openconnect timeout     (vpnc-script *does* run, but down_cmds do not)
#   - reconnect failure       (same as above)
#   - IPsec monitor crash     (SA may still be active in charon)
#
# When cmd_stop performs a clean shutdown it removes the PID file itself.
# The watchdog uses the absence of the PID file as a "clean stop" signal
# and exits without re-running down_cmds (avoiding double execution).
#
# Usage: vpn_watchdog.sh <interface_id> <pid_file> <dnsmasq_dir> <config_file>

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
. "$SCRIPT_DIR/funcs.sh"

VPN_INTERFACE_ID=$1
PID_FILE=$2
DNSMASQ_DIR=$3
CONFIG_FILE=$4

if [ -z "$VPN_INTERFACE_ID" ] || [ -z "$PID_FILE" ] || [ -z "$DNSMASQ_DIR" ] || [ -z "$CONFIG_FILE" ]; then
  echo "Usage: vpn_watchdog.sh <interface_id> <pid_file> <dnsmasq_dir> <config_file>" >&2
  exit 1
fi

# Derive VPN name and type from the config file path
export VPNNAME
VPNNAME=$(basename "$CONFIG_FILE" .json)
export VPN_CONFIG_FILE="$CONFIG_FILE"

vpn_type=$(get_vpn_type "$CONFIG_FILE")

# Compute the interface name for log messages
export VPN_IF
case "$vpn_type" in
  ipsec) VPN_IF="xfrm${VPN_INTERFACE_ID}" ;;
  *)     VPN_IF="tun${VPN_INTERFACE_ID}" ;;
esac

# Snapshot VPN PID at startup
if [ -f "$PID_FILE" ]; then
  VPN_PID=$(cat "$PID_FILE" 2>/dev/null)
  if [ -z "$VPN_PID" ]; then
    echo "vpn_watchdog[$VPNNAME]: empty PID file, exiting." >&2
    exit 1
  fi
else
  echo "vpn_watchdog[$VPNNAME]: PID file not found, exiting." >&2
  exit 1
fi

echo "vpn_watchdog[$VPNNAME]: watching PID $VPN_PID (${VPN_IF})"

# ── Wait for VPN process to die ──────────────────────────────────────────────

while kill -0 "$VPN_PID" 2>/dev/null; do
  sleep 5
done

echo "vpn_watchdog[$VPNNAME]: PID $VPN_PID is gone"

# ── Determine whether this was a clean stop ───────────────────────────────────
# cmd_stop removes the PID file as its final cleanup step.
sleep 1

if [ ! -f "$PID_FILE" ]; then
  echo "vpn_watchdog[$VPNNAME]: PID file gone — clean stop by cmd_stop, nothing to do."
  exit 0
fi

# ── Unclean exit: run full teardown ──────────────────────────────────────────

echo "vpn_watchdog[$VPNNAME]: unclean exit detected, running teardown for ${VPN_IF}"

# Load the driver for type-specific teardown (e.g. terminate IPsec SA, delete xfrm if)
DRIVER_FILE="$SCRIPT_DIR/vpn_driver_${vpn_type}.sh"
if [ -f "$DRIVER_FILE" ]; then
  . "$DRIVER_FILE"
  # Parse common config so driver_disconnect has vpn_log_file etc.
  eval "$(parse_json "$CONFIG_FILE" vpn_)"
  driver_disconnect 2>/dev/null || true
fi

# Run down_cmds from the VPN config
if command -v jq >/dev/null 2>&1 && [ -f "$CONFIG_FILE" ]; then
  down_cmds=$(jq -r '.down_cmds // [] | .[]' "$CONFIG_FILE" 2>/dev/null)
  if [ -n "$down_cmds" ]; then
    echo "vpn_watchdog[$VPNNAME]: running down_cmds"
    echo "$down_cmds" | while read -r cmd; do
      if [ -n "$cmd" ]; then
        echo "  $cmd"
        $cmd
      fi
    done
  fi
fi

# Remove the MASQUERADE rule added at vpn-up
echo "vpn_watchdog[$VPNNAME]: removing MASQUERADE on ${VPN_IF}"
vpn_masq_del "$VPN_IF"

# Remove all policy routing rules pointing to this VPN's routing table
echo "vpn_watchdog[$VPNNAME]: removing IP routing rules for table $VPN_INTERFACE_ID"
while sudo ip rule del table "$VPN_INTERFACE_ID" 2>/dev/null; do :; done

# Remove the dnsmasq config
echo "vpn_watchdog[$VPNNAME]: removing dnsmasq config"
rm -f "${DNSMASQ_DIR}/vpn${VPN_INTERFACE_ID}"-*.conf

supervisorctl restart dnsmasq 2>/dev/null || pkill -TERM -x dnsmasq 2>/dev/null || true
pkill -HUP -x squid   2>/dev/null || true

rm -f "$PID_FILE"

echo "vpn_watchdog[$VPNNAME]: teardown complete for ${VPN_IF}"
