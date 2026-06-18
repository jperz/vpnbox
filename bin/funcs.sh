function parse_json {
   local file=$1
   local prefix=$2
   # Exports scalar fields and simple arrays (arrays of scalars) as env vars.
   # Skips object-type values (type-specific sub-objects like "openconnect", "ipsec")
   # and arrays whose first element is an object (e.g. "keepalive").
   jq -r --arg prefix "$prefix" '
     to_entries | .[] |
     select(.value |
       (type == "string" or type == "number" or type == "boolean" or type == "null") or
       (type == "array" and (length == 0 or (.[0] | type) != "object"))
     ) |
     "export " + $prefix + .key + "=\"" +
     (.value | if type == "array" then join("\n") elif type == "null" then "" else tostring end) +
     "\""
   ' "$file"
}

function get_vpn_type {
  jq -r '.type // "openconnect"' "$1"
}

# Fill in defaults for common config fields left unset or empty in the VPN JSON.
# Pid/log files default to /data/run/<interface_id>.pid and
# /data/logs/<interface_id>.log. Call after parse_json, before the values are used.
function apply_common_defaults {
  : "${vpn_pid_file:=/data/run/${vpn_interface_id}.pid}"
  : "${vpn_log_file:=/data/logs/${vpn_interface_id}.log}"
}

# NAT outgoing traffic on the VPN interface so packets forwarded/proxied through
# the tunnel (LAN clients, squid, dante) leave with the tunnel's source address
# instead of the box's. Added on vpn-up, removed on vpn-down. Idempotent: the -C
# check avoids stacking duplicate rules across reconnects.
function vpn_masq_add {
  local iface=$1
  [ -n "$iface" ] || return 0
  sudo iptables -t nat -C POSTROUTING -o "$iface" -j MASQUERADE 2>/dev/null \
    || sudo iptables -t nat -A POSTROUTING -o "$iface" -j MASQUERADE
}

# Remove every MASQUERADE rule for this interface (loop clears any duplicates a
# prior unclean run may have left).
function vpn_masq_del {
  local iface=$1
  [ -n "$iface" ] || return 0
  while sudo iptables -t nat -D POSTROUTING -o "$iface" -j MASQUERADE 2>/dev/null; do :; done
}
