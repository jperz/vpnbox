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
  local config_file server username password additional_args ca cert key

  config_file=$(jq -r '.openvpn.config_file // ""' "$VPN_CONFIG_FILE")
  # Default to /etc/openvpn.conf unless the config specifies one.
  [ -n "$config_file" ] || config_file="/etc/openvpn.conf"
  server=$(jq -r '.openvpn.server // ""' "$VPN_CONFIG_FILE")

  # OpenVPN wants "--remote host port"; accept the standard "host:port" notation
  # too. Convert the port-separating colon (the last one, so bracketed IPv6
  # literals survive) to a space when it is followed by a numeric port.
  if [[ "$server" == *:* ]]; then
    local host="${server%:*}" port="${server##*:}"
    [[ "$port" =~ ^[0-9]+$ ]] && server="$host $port"
  fi
  username=$(jq -r '.openvpn.username // ""' "$VPN_CONFIG_FILE")
  password=$(jq -r '.openvpn.password // ""' "$VPN_CONFIG_FILE")
  ca=$(jq -r '.openvpn.ca // ""' "$VPN_CONFIG_FILE")
  cert=$(jq -r '.openvpn.cert // ""' "$VPN_CONFIG_FILE")
  key=$(jq -r '.openvpn.key // ""' "$VPN_CONFIG_FILE")
  additional_args=$(jq -r '.openvpn.additional_args // ""' "$VPN_CONFIG_FILE")

  [ "$vpn_debug" = "true" ] && additional_args="$additional_args --verb 5"

  local config_arg=""
  [ -n "$config_file" ] && config_arg="--config $config_file"

  # --route-noexec suppresses every route OpenVPN would install, including the
  # default route that "redirect-gateway" normally adds. Detect that directive
  # in the config so the updown script can install a default route into the
  # VPN-specific table instead. (Server-pushed redirect-gateway isn't visible
  # here, only what's in the local config file.)
  local redirect_gateway="false"
  if [ -f "$config_file" ] && grep -qE '^[[:space:]]*redirect-gateway([[:space:]]|$)' "$config_file"; then
    redirect_gateway="true"
  fi

  # Server hostname (optionally "host port"); --remote overrides any in the config.
  local remote_arg=""
  [ -n "$server" ] && remote_arg="--remote $server"

  # Inline certificates: write each PEM blob to a temp file and point OpenVPN at it.
  # Removed by driver_disconnect or when the watchdog cleans up.
  local cert_args=""
  if [ -n "$ca" ]; then
    local ca_file="/tmp/routehouse_openvpn_ca_${VPNNAME}.pem"
    printf '%s\n' "$ca" > "$ca_file"; chmod 600 "$ca_file"
    cert_args="$cert_args --ca $ca_file"
  fi
  if [ -n "$cert" ]; then
    local cert_file="/tmp/routehouse_openvpn_cert_${VPNNAME}.pem"
    printf '%s\n' "$cert" > "$cert_file"; chmod 600 "$cert_file"
    cert_args="$cert_args --cert $cert_file"
  fi
  if [ -n "$key" ]; then
    local key_file="/tmp/routehouse_openvpn_key_${VPNNAME}.pem"
    printf '%s\n' "$key" > "$key_file"; chmod 600 "$key_file"
    cert_args="$cert_args --key $key_file"
  fi

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
    echo "  server=$server"
    echo "  username=$username"
    echo "  ca=$([ -n "$ca" ] && echo yes || echo no) cert=$([ -n "$cert" ] && echo yes || echo no) key=$([ -n "$key" ] && echo yes || echo no)"
    echo "  interface=$VPN_IF"
    echo "============================="
  fi

  # --route-noexec: suppress OpenVPN's route modifications; our updown script
  # handles routing into the VPN-specific table instead.
  # --up-restart: re-run the up script after each reconnect.
  sudo openvpn \
    $config_arg \
    $remote_arg \
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
    --setenv REDIRECT_GATEWAY "$redirect_gateway" \
    $auth_arg \
    $cert_args \
    $additional_args
}

driver_disconnect() {
  rm -f "/tmp/routehouse_openvpn_creds_${VPNNAME}.txt" \
        "/tmp/routehouse_openvpn_ca_${VPNNAME}.pem" \
        "/tmp/routehouse_openvpn_cert_${VPNNAME}.pem" \
        "/tmp/routehouse_openvpn_key_${VPNNAME}.pem"
}
