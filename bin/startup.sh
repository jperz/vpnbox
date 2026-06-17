#!/bin/sh

cp /etc/resolv.conf.docker-replace /etc/resolv.conf

/sbin/iptables -F
/sbin/iptables -F -t nat

# ── SSH setup ──────────────────────────────────────────────────────────────
# Generate host keys on first boot (never bake static keys into the image).
ssh-keygen -A

# Ensure the authorized_keys directory exists on the data volume.
# Add public keys to /data/ssh/authorized_keys on the host/volume.
mkdir -p /data/ssh
mkdir -p /data/bird
chmod 700 /data/ssh
if [ ! -s /data/ssh/authorized_keys ]; then
  echo "[startup] WARNING: /data/ssh/authorized_keys is missing or empty — tunnel user cannot authenticate"
else
  chmod 600 /data/ssh/authorized_keys
fi

/usr/bin/supervisord -n -c /etc/supervisor.conf
