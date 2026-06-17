#!/bin/bash
# IPsec VPN driver for vpn.sh, using strongSwan (charon + swanctl).
# Type-specific settings live under the "ipsec" key in the VPN JSON config.
#
# Driver contract (expected by vpn.sh):
#   DRIVER_IF_PREFIX  -- "xfrm"; vpn.sh appends interface_id to get e.g. xfrm50
#   driver_connect()  -- create XFRM interface, load swanctl config, initiate SA,
#                        start monitor process that owns the pid_file
#   driver_disconnect() -- terminate SA, remove XFRM interface, unload config
#
# The monitor subprocess (invoked as: bash vpn_driver_ipsec.sh _monitor <args>)
# watches the SA and performs cleanup when it receives SIGTERM.

# ── Monitor mode ─────────────────────────────────────────────────────────────
# Must be checked before any driver definitions so the monitor can exit cleanly
# without evaluating the rest of the file.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && [ "${1:-}" = "_monitor" ]; then
  _mon_name=$2
  _mon_if=$3
  _mon_pidfile=$4

  # Write PID immediately so vpn.sh's watchdog can find it
  echo $$ > "$_mon_pidfile"

  _mon_cleanup() {
    echo "ipsec monitor[$_mon_name]: received signal, terminating SA"
    swanctl --terminate --ike "$_mon_name" 2>/dev/null || true
    swanctl --unload-conns --conn "$_mon_name" 2>/dev/null || true
    ip link del "$_mon_if" 2>/dev/null || true
    rm -f "/tmp/vpnbox_updown_${_mon_name}.sh" "/tmp/vpnbox_swanctl_${_mon_name}.conf"
    rm -f "$_mon_pidfile"
    exit 0
  }
  trap _mon_cleanup SIGTERM SIGINT

  echo "ipsec monitor[$_mon_name]: watching SA on $_mon_if (PID $$)"
  while true; do
    sleep 15
    if ! swanctl --list-sas 2>/dev/null | grep -q "^${_mon_name}:[[:space:]]"; then
      echo "ipsec monitor[$_mon_name]: SA no longer active, exiting"
      break
    fi
  done

  # SA dropped without a signal — let watchdog handle teardown
  ip link del "$_mon_if" 2>/dev/null || true
  rm -f "$_mon_pidfile"
  exit 1
fi

# ── Driver definitions ────────────────────────────────────────────────────────
# Only reached when this file is sourced by vpn.sh (not executed directly).

DRIVER_IF_PREFIX="xfrm"

_ipsec_read_config() {
  ipsec_mode=$(jq -r '.ipsec.mode // "roadwarrior"' "$VPN_CONFIG_FILE")
  ipsec_remote_gateway=$(jq -r '.ipsec.remote_gateway // empty' "$VPN_CONFIG_FILE")
  ipsec_auth_type=$(jq -r '.ipsec.auth_type // "eap"' "$VPN_CONFIG_FILE")
  ipsec_local_id=$(jq -r '.ipsec.local_id // "%any"' "$VPN_CONFIG_FILE")
  ipsec_remote_id=$(jq -r '.ipsec.remote_id // "%any"' "$VPN_CONFIG_FILE")
  ipsec_virtual_ip=$(jq -r '.ipsec.virtual_ip // "true"' "$VPN_CONFIG_FILE")
  ipsec_eap_username=$(jq -r '.ipsec.eap_username // ""' "$VPN_CONFIG_FILE")
  ipsec_eap_password=$(jq -r '.ipsec.eap_password // ""' "$VPN_CONFIG_FILE")
  ipsec_psk=$(jq -r '.ipsec.psk // ""' "$VPN_CONFIG_FILE")
  ipsec_xauth_username=$(jq -r '.ipsec.xauth_username // ""' "$VPN_CONFIG_FILE")
  ipsec_xauth_password=$(jq -r '.ipsec.xauth_password // ""' "$VPN_CONFIG_FILE")
  ipsec_aggressive=$(jq -r '.ipsec.aggressive // false' "$VPN_CONFIG_FILE")
  ipsec_local_cert=$(jq -r '.ipsec.local_cert // ""' "$VPN_CONFIG_FILE")
  ipsec_local_key=$(jq -r '.ipsec.local_key // ""' "$VPN_CONFIG_FILE")
  ipsec_remote_subnets=$(jq -r '.ipsec.remote_subnets // [] | .[]' "$VPN_CONFIG_FILE")
  ipsec_ike_proposals=$(jq -r '.ipsec.ike_proposals // ""' "$VPN_CONFIG_FILE")
  ipsec_esp_proposals=$(jq -r '.ipsec.esp_proposals // ""' "$VPN_CONFIG_FILE")
}

_ipsec_generate_swanctl_conf() {
  # remote traffic selectors: full tunnel for roadwarrior, explicit subnets for site-to-site
  local remote_ts="0.0.0.0/0"
  if [ "$ipsec_mode" = "site-to-site" ] && [ -n "$ipsec_remote_subnets" ]; then
    remote_ts=$(echo "$ipsec_remote_subnets" | paste -sd ',' -)
  fi

  local vips_line=""
  if [ "$ipsec_mode" = "roadwarrior" ] && [ "$ipsec_virtual_ip" = "true" ]; then
    vips_line="    vips = 0.0.0.0"
  fi

  # XAuth-PSK (Cisco/Juniper/Mikrotik-style "PSK + username/password") requires
  # IKEv1. Aggressive Mode is only needed when the gateway hosts several
  # distinct group PSKs and must pick one by ID before the DH exchange
  # completes; a single shared PSK (the common case) works fine with the
  # IKEv1 default, Main Mode, so it's opt-in here rather than forced on.
  local ike_version="2"
  local aggressive_line=""
  if [ "$ipsec_auth_type" = "xauth-psk" ]; then
    ike_version="1"
    if [ "$ipsec_aggressive" = "true" ]; then
      aggressive_line="    aggressive = yes"
    fi
  fi

  local proposals_line=""
  if [ -n "$ipsec_ike_proposals" ]; then
    proposals_line="    proposals = ${ipsec_ike_proposals}"
  fi

  local esp_proposals_line=""
  if [ -n "$ipsec_esp_proposals" ]; then
    esp_proposals_line="        esp_proposals = ${ipsec_esp_proposals}"
  fi

  local local_block remote_block
  case "$ipsec_auth_type" in
    eap)
      local_block="    local {
      auth = eap
      id = $ipsec_local_id
    }"
      remote_block="    remote {
      auth = pubkey
      id = $ipsec_remote_id
    }"
      ;;
    psk)
      local_block="    local {
      auth = psk
      id = $ipsec_local_id
    }"
      remote_block="    remote {
      auth = psk
      id = $ipsec_remote_id
    }"
      ;;
    xauth-psk)
      # Omit local/remote id unless explicitly set: many PSK+XAuth gateways use
      # one shared PSK for all clients and don't expect/match a custom group
      # name — sending an arbitrary one there gets silently dropped (no
      # NO_PROPOSAL/error response at all).
      local xauthpsk_local_id_line="" xauthpsk_remote_id_line=""
      if [ -n "$ipsec_local_id" ] && [ "$ipsec_local_id" != "%any" ]; then
        xauthpsk_local_id_line="
      id = $ipsec_local_id"
      fi
      if [ -n "$ipsec_remote_id" ] && [ "$ipsec_remote_id" != "%any" ]; then
        xauthpsk_remote_id_line="
      id = $ipsec_remote_id"
      fi
      local_block="    local {
      auth = psk${xauthpsk_local_id_line}
    }
    local-xauth {
      auth = xauth
      xauth_id = $ipsec_xauth_username
    }"
      remote_block="    remote {
      auth = psk${xauthpsk_remote_id_line}
    }"
      ;;
    cert)
      local_block="    local {
      auth = pubkey
      id = $ipsec_local_id
      certs = $ipsec_local_cert
    }"
      remote_block="    remote {
      auth = pubkey
      id = $ipsec_remote_id
    }"
      ;;
  esac

  cat <<EOF
connections {
  ${VPNNAME} {
    remote_addrs = ${ipsec_remote_gateway}
    version = ${ike_version}
${proposals_line}
${aggressive_line}
${vips_line}
${local_block}
${remote_block}
    children {
      ${VPNNAME} {
        remote_ts = ${remote_ts}
${esp_proposals_line}
        if_id_out = ${vpn_interface_id}
        if_id_in = ${vpn_interface_id}
        updown = /tmp/vpnbox_updown_${VPNNAME}.sh
        start_action = none
        close_action = none
        dpd_action = clear
      }
    }
  }
}

secrets {
EOF

  case "$ipsec_auth_type" in
    eap)
      cat <<EOF
  eap-${VPNNAME} {
    id = ${ipsec_local_id}
    secret = "${ipsec_eap_password}"
  }
EOF
      ;;
    psk)
      cat <<EOF
  ike-${VPNNAME} {
    secret = "${ipsec_psk}"
  }
EOF
      ;;
    xauth-psk)
      cat <<EOF
  ike-${VPNNAME} {
    secret = "${ipsec_psk}"
  }
  xauth-${VPNNAME} {
    id = ${ipsec_xauth_username}
    secret = "${ipsec_xauth_password}"
  }
EOF
      ;;
    cert)
      cat <<EOF
  private-${VPNNAME} {
    file = ${ipsec_local_key}
  }
EOF
      ;;
  esac

  echo "}"
}

_ipsec_create_updown_wrapper() {
  cat > "/tmp/vpnbox_updown_${VPNNAME}.sh" <<EOF
#!/bin/bash
# Per-VPN updown wrapper — sets vpnbox context for ipsec_updown.sh
export VPNNAME="${VPNNAME}"
export VPN_IF="${VPN_IF}"
export VPN_INTERFACE_ID="${vpn_interface_id}"
export VPN_CONFIG_FILE="${VPN_CONFIG_FILE}"
export DNSMASQ_DIR="${DNSMASQ_DIR}"
exec /usr/local/vpnbox/bin/ipsec_updown.sh "\$@"
EOF
  chmod +x "/tmp/vpnbox_updown_${VPNNAME}.sh"
}

driver_connect() {
  _ipsec_read_config

  if [ -z "$ipsec_remote_gateway" ]; then
    echo "Error: 'ipsec.remote_gateway' not set in VPN config" >&2
    return 1
  fi

  if ! swanctl --stats >/dev/null 2>&1; then
    echo "Error: charon is not running — ensure the container started with IPsec support" >&2
    return 1
  fi

  # Find the default-route interface to use as XFRM parent
  local parent_dev
  parent_dev=$(ip route show default | awk '/default/{print $5; exit}')
  parent_dev=${parent_dev:-eth0}

  # Create XFRM interface (idempotent: ignore error if already exists)
  ip link add "$VPN_IF" type xfrm dev "$parent_dev" if_id "$vpn_interface_id" 2>/dev/null || true
  ip link set "$VPN_IF" up

  _ipsec_create_updown_wrapper

  local conf_file="/tmp/vpnbox_swanctl_${VPNNAME}.conf"
  _ipsec_generate_swanctl_conf > "$conf_file"

  if [ "$vpn_debug" = "true" ]; then
    echo "=== DEBUG: IPsec swanctl config ==="
    cat "$conf_file"
    echo "==================================="
  fi

  swanctl --load-conns --file "$conf_file" >> "$vpn_log_file" 2>&1
  swanctl --load-creds --file "$conf_file" >> "$vpn_log_file" 2>&1
  local load_res=$?
  rm -f "$conf_file"

  if [ $load_res -ne 0 ]; then
    echo "Error: failed to load swanctl config" >&2
    ip link del "$VPN_IF" 2>/dev/null || true
    return 1
  fi

  echo "Initiating IPsec SA for $VPNNAME..."
  swanctl --initiate --child "$VPNNAME" >> "$vpn_log_file" 2>&1
  local init_res=$?

  if [ $init_res -ne 0 ]; then
    echo "Error: swanctl --initiate failed" >&2
    swanctl --unload-conns --conn "$VPNNAME" 2>/dev/null || true
    ip link del "$VPN_IF" 2>/dev/null || true
    return 1
  fi

  # Start the monitor subprocess; it writes its own PID to vpn_pid_file
  nohup bash "$SCRIPT_DIR/vpn_driver_ipsec.sh" _monitor \
    "$VPNNAME" "$VPN_IF" "$vpn_pid_file" >> "$vpn_log_file" 2>&1 &

  sleep 1  # allow monitor to write its PID before vpn.sh starts the watchdog
  return 0
}

driver_disconnect() {
  echo "Terminating IPsec SA for $VPNNAME..."
  swanctl --terminate --ike "$VPNNAME" >> "$vpn_log_file" 2>&1 || true
  swanctl --unload-conns --conn "$VPNNAME" 2>/dev/null || true
  ip link del "$VPN_IF" 2>/dev/null || true
  rm -f "/tmp/vpnbox_updown_${VPNNAME}.sh"
}
