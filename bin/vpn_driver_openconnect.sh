#!/bin/bash
# OpenConnect VPN driver for vpn.sh.
# Type-specific settings live under the "openconnect" key in the VPN JSON config.
#
# Driver contract (expected by vpn.sh):
#   DRIVER_IF_PREFIX  -- interface name prefix; vpn.sh appends interface_id
#   driver_connect()  -- start the VPN, write PID to $vpn_pid_file; return 0 on success
#   driver_disconnect() -- type-specific teardown called before killing the main process

DRIVER_IF_PREFIX="tun"

driver_connect() {
  local server username password config_file protocol additional_args

  server=$(jq -r '.openconnect.server // empty' "$VPN_CONFIG_FILE")
  username=$(jq -r '.openconnect.username // empty' "$VPN_CONFIG_FILE")
  password=$(jq -r '.openconnect.password // empty' "$VPN_CONFIG_FILE")
  config_file=$(jq -r '.openconnect.config_file // "/etc/openconnect.cfg"' "$VPN_CONFIG_FILE")
  protocol=$(jq -r '.openconnect.protocol // "anyconnect"' "$VPN_CONFIG_FILE")
  additional_args=$(jq -r '.openconnect.additional_args // ""' "$VPN_CONFIG_FILE")

  if [ -z "$server" ]; then
    echo "Error: 'openconnect.server' not set in VPN config" >&2
    return 1
  fi

  [ "$vpn_debug" = "true" ] && additional_args="$additional_args -v -v --dump-http-traffic"

  local first_domain domains_flat
  first_domain=$(echo "$vpn_additional_domains" | head -n1)
  domains_flat=$(echo "$vpn_additional_domains" | tr '\n' ' ' | xargs)

  if [ "$vpn_debug" = "true" ]; then
    local full_cmd="openconnect --config=$(printf '%q' "$config_file") --server=$(printf '%q' "$server") --user=$(printf '%q' "$username") --pid-file=$(printf '%q' "$vpn_pid_file") --interface=$(printf '%q' "$VPN_IF") --protocol=$(printf '%q' "$protocol")${additional_args:+ $additional_args}"
    {
      echo "=== DEBUG: openconnect driver ==="
      echo "  server=$server"
      echo "  username=$username"
      echo "  protocol=$protocol"
      echo "  interface=$VPN_IF"
      echo "=== Full openconnect command ==="
      echo "  $full_cmd"
      echo "================================="
    } | tee -a "$vpn_log_file"
  fi

  echo "$password" | sudo env \
    VPNNAME="$VPNNAME" \
    VPN_FIRST_DOMAIN="$first_domain" \
    VPN_ADDITIONAL_DOMAINS="$domains_flat" \
    VPN_CONFIG_FILE="$VPN_CONFIG_FILE" \
  openconnect \
    --config="$config_file" \
    --server="$server" \
    --user="$username" \
    --pid-file="$vpn_pid_file" \
    --interface="$VPN_IF" \
    --protocol="$protocol" \
    $additional_args \
  2>&1 >> "$vpn_log_file"
}

driver_disconnect() {
  : # vpnc-script handles routing/DNS/nftables cleanup when openconnect receives SIGTERM
}
