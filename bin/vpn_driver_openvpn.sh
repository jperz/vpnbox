#!/bin/bash
# OpenVPN driver for vpn.sh.
# Type-specific settings live under the "openvpn" key in the VPN JSON config.
#
# Driver contract (expected by vpn.sh):
#   DRIVER_IF_PREFIX  -- "tun"; vpn.sh appends interface_id to get e.g. tun43
#   driver_connect()  -- start openvpn as a daemon, write PID via --writepid
#   driver_disconnect() -- remove credentials temp file

DRIVER_IF_PREFIX="tun"

driver_connect() {
  local config_file username password additional_args

  config_file=$(jq -r '.openvpn.config_file // ""' "$VPN_CONFIG_FILE")
  username=$(jq -r '.openvpn.username // ""' "$VPN_CONFIG_FILE")
  password=$(jq -r '.openvpn.password // ""' "$VPN_CONFIG_FILE")
  additional_args=$(jq -r '.openvpn.additional_args // ""' "$VPN_CONFIG_FILE")

  [ "$vpn_debug" = "true" ] && additional_args="$additional_args --verb 5"

  local config_arg=""
  [ -n "$config_file" ] && config_arg="--config $config_file"

  # Write credentials to a temp file; OpenVPN reads it once on connect.
  # Removed by driver_disconnect or when the watchdog cleans up.
  local auth_arg=""
  if [ -n "$username" ]; then
    local creds_file="/tmp/routehouse_openvpn_creds_${VPNNAME}.txt"
    printf '%s\n%s\n' "$username" "$password" > "$creds_file"
    chmod 600 "$creds_file"
    auth_arg="--auth-user-pass $creds_file"
  fi

  if [ "$vpn_debug" = "true" ]; then
    echo "=== DEBUG: openvpn driver ==="
    echo "  config=$config_file"
    echo "  username=$username"
    echo "  interface=$VPN_IF"
    echo "============================="
  fi

  # --route-noexec: suppress OpenVPN's route modifications; our updown script
  # handles routing into the VPN-specific table instead.
  # --up-restart: re-run the up script after each reconnect.
  sudo openvpn \
    $config_arg \
    --dev "$VPN_IF" \
    --writepid "$vpn_pid_file" \
    --daemon \
    --log-append "$vpn_log_file" \
    --script-security 2 \
    --route-noexec \
    --up   /usr/local/routehouse/bin/openvpn_updown.sh \
    --down /usr/local/routehouse/bin/openvpn_updown.sh \
    --up-restart \
    --setenv VPNNAME          "$VPNNAME" \
    --setenv VPN_INTERFACE_ID "$vpn_interface_id" \
    --setenv VPN_CONFIG_FILE  "$VPN_CONFIG_FILE" \
    --setenv DNSMASQ_DIR      "$DNSMASQ_DIR" \
    $auth_arg \
    $additional_args
}

driver_disconnect() {
  rm -f "/tmp/routehouse_openvpn_creds_${VPNNAME}.txt"
}
