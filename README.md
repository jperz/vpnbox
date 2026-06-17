<div align="center">

<img src="web/routehouse.png" alt="Routehouse" width="140">

# Routehouse

**One box. Every VPN. Shared by the whole team.**

A self-hosted Docker appliance that connects to **many VPNs at once** — Cisco AnyConnect, OpenConnect, OpenVPN and IPsec/IKEv2 — and exposes them to your entire LAN through a proxy, a SOCKS5 endpoint and SSH jump tunnels. No VPN client on anyone's laptop. No fighting over which tunnel is "currently connected".

Comes with a simple dashboard - or use CLI.

</div>

---

## What is this?

You probably know the pain: a customer hands you a VPN profile, you connect, and suddenly your whole machine reroutes — Slack drops, your other customer's VPN disconnects, and your DNS starts resolving everything through *their* servers. Connect to a second customer? Good luck if their internal network uses `10.0.0.0/8` too.

**Routehouse solves this by moving all your VPNs into a single, always-on container.** Each tunnel lives in its own routing table with its own DNS. They run side by side, permanently, and your team reaches each one through a shared proxy — picking the right tunnel automatically based on the destination address or domain.

Think of it as a **VPN switchboard for your team**: dial any internal host on any customer network, from any machine on the LAN, without ever installing or toggling a VPN client again.

---

## Why Routehouse?

### 🔀 Run many VPNs at the same time
Most VPN clients are jealous — they grab the default route and tear down everything else. Routehouse gives **every VPN its own network interface and its own Linux routing table**. Ten tunnels can be up simultaneously and none of them interfere with the others (or with your normal traffic).

### 🧩 Handle overlapping IP ranges
Customer A uses `10.0.0.0/8`. So does Customer B. A normal host can't route to both. Routehouse uses **policy-based routing** (`ip rule` + per-tunnel tables): traffic is steered into the correct tunnel based on the **specific destination route** you assign to each VPN — and for DNS-based services, by the **domain** being resolved. Overlap stops being a deal-breaker.

### 👥 Share VPN access across the whole team
Connect once, on the box — then **everyone on the LAN uses it**. Routehouse publishes three front doors:
- **HTTP/HTTPS proxy** (Squid, port `3128`)
- **SOCKS5** (Dante, port `1080`)
- **SSH jump host** (key-only tunnel user, port `22`)

No more "can you reconnect, I need to reach the test server" in the team chat. No per-seat VPN licenses. One connection, shared.

### 🔒 Security by least-route — and no DNS leaks
Routehouse is built so a tunnel **only carries the traffic it should**:
- **Route only what you need.** Each VPN gets an explicit allow-list of destination subnets/hosts. Nothing else is ever sent into a customer's network — and a customer's tunnel never becomes a path to the open internet.
- **No DNS bleeding.** DNS queries for a VPN's internal domains (e.g. `*.customer.intern`) are sent **only** to that VPN's DNS servers — and the answers don't escape to anyone else. All other lookups go to your normal resolver. A customer's DNS server never sees your unrelated queries, and your queries never leak into their infrastructure.
- **Resolve-then-route.** For services known only by hostname, dnsmasq adds each resolved IP to an `nftables` set on the fly, so even dynamically-discovered hosts are routed through the right tunnel — and nowhere else.

---

## Features

| | |
|---|---|
| **Protocols** | OpenConnect (AnyConnect, GlobalProtect, Pulse/Juniper, FortiGate, F5, Array), OpenVPN, IPsec/IKEv2 & IKEv1 — [full list ↓](#supported-protocols) |
| **Per-VPN isolation** | Dedicated interface + routing table + DNS scope for every tunnel |
| **Client access** | Squid HTTP proxy · Dante SOCKS5 · SSH jump host |
| **Split DNS** | Per-domain forwarding to each VPN's resolver, leak-free |
| **Auto-routing** | DNS lookups auto-add `/32` routes for hostname-only services — [how ↓](#-dns-lookups-that-build-their-own-routes) |
| **Route export** | Advertise reachable subnets to your LAN via BIRD / RIPv2 — [how ↓](#-re-announcing-vpn-routes-to-your-lan-bird--ripv2) |
| **Health** | Per-VPN keepalive + watchdog with automatic cleanup |
| **Web dashboard** | Start/stop tunnels, edit configs, toggle services, tail logs |
| **Config as data** | Each VPN is a single declarative JSON file |

---

## Supported protocols

Routehouse drives three best-in-class open-source VPN engines, giving you broad gateway coverage from a single appliance.

### SSL/TLS VPNs — via OpenConnect
Set `openconnect.protocol` to match your gateway. OpenConnect speaks every major proprietary SSL-VPN protocol:

| `protocol` | Gateway |
|---|---|
| `anyconnect` | Cisco AnyConnect (ASA / Firepower) |
| `gp` | Palo Alto Networks GlobalProtect |
| `nc` | Juniper Network Connect |
| `pulse` | Juniper / Pulse Connect Secure (Ivanti) |
| `fortinet` | Fortinet FortiGate SSL VPN |
| `f5` | F5 BIG-IP Edge / APM |
| `array` | Array Networks SSL VPN |

### OpenVPN
The full OpenVPN protocol over **UDP or TCP**, configured from a standard `.ovpn` profile. All common authentication modes are supported: TLS/PKI certificates, static keys, `tls-auth`/`tls-crypt`, and username + password (`auth-user-pass`) — including 2FA/OTP appended to the password.

### IPsec — via strongSwan
| Mode | Auth | Typical use |
|---|---|---|
| **IKEv2 road-warrior** | EAP (user/pass), PSK, or certificate | Modern strongSwan / RouterOS / Windows-style gateways |
| **IKEv1 road-warrior** | **XAuth + PSK**, aggressive mode | Classic Cisco IOS / ASA "group VPN" |
| **Site-to-site** | PSK or certificate | Connect whole subnets (`remote_subnets`) router-to-router |

> Cisco's Unity extension (split-include routes pushed by the gateway) is supported for IKEv1 PSK+XAuth — Routehouse enables `charon.cisco_unity` so those routes are honoured automatically.

---

## How it works

```
                LAN clients (browsers, ssh, apps)
            HTTP :3128 │ SOCKS5 :1080 │ SSH :22 │ Web :3100
                       ▼
        ┌───────────────────────────────────────────────┐
        │                  Routehouse container         │
        │                                               │
        │   Squid / Dante / sshd  ──┐                   │
        │                           │ policy routing    │
        │   dnsmasq (split DNS) ────┤ (ip rule + tables)│
        │                           ▼                   │
        │   tun42 ── Customer A   xfrm50 ── Customer B  │
        │   tun43 ── Customer C   ...                   │
        └────┼────────────┼───────────────┼─────────────┘
             ▼            ▼               ▼
        VPN gateway   VPN gateway     VPN gateway
```

Every connected VPN gets interface `tunNN` / `xfrmNN` and routing table `NN` (where `NN` is the config's `interface_id`). Policy rules direct matching destination traffic into the matching table; dnsmasq forwards matching domains to the matching tunnel's DNS. Squid, Dante and sshd sit in front and let the whole LAN ride along.

---

## Under the hood

Two mechanisms do most of the heavy lifting and are worth understanding.

### 🪄 DNS lookups that build their own routes

Internal services usually live behind a *hostname*, not a fixed IP — and that IP can change without notice. Instead of making you chase IPs, Routehouse turns **every DNS lookup into a routing decision**. List a VPN's internal domains under `additional_domains` and this chain kicks in:

1. **Split DNS.** dnsmasq forwards queries for those domains **only** to that VPN's own DNS servers (and nothing else leaks to them — see [security](#-security-by-least-route--and-no-dns-leaks)).
2. **Resolve → set.** The instant a name resolves, dnsmasq writes the answer — the exact **`/32` host address** — into a per-VPN `nftables` set (via its `nftset=` directive).
3. **Set → route.** A kernel `fwmark` rule matches any packet whose destination is in that set and steers it into the VPN's routing table.

So when someone asks for `wiki.acme.intern`, the name is resolved through the correct tunnel **and** the resolved host is routed through it — automatically, the moment it's looked up. No daemon tailing logs, no manually maintained route list. If the host's IP changes, the next lookup re-points the route for free. Addresses that *aren't* reachable inside the VPN simply fall through to the normal table, so nothing breaks.

This is what lets you point `manual_routes` at just the handful of subnets you truly need, and let everything discovered-by-name route itself on demand.

### 📡 Re-announcing VPN routes to your LAN (BIRD → RIPv2)

Reaching a tunnel through the box's proxies is perfect for clients — but sometimes you want other **routers** on your network to know natively that *"the path to `10.50.0.0/16` runs through Routehouse"*, so any device can reach those subnets without configuring a proxy at all.

For that, Routehouse runs the [BIRD](https://bird.network.cz/) routing daemon. Any prefix you list under a VPN's `exported_routes`:

1. is injected into BIRD as a static route when the VPN connects, and
2. is **advertised over RIPv2** to the rest of your network.

Your L3 switch / core router learns the prefix dynamically and starts forwarding that subnet's traffic to the box, which carries it into the tunnel (with NAT applied on the way out). Stop the VPN and the announcement is **withdrawn automatically** — peers age the route out, so you never leave stale paths pointing at a dead tunnel. It's a clean way to extend a customer network to your whole site without touching a single client.

---

## Setup

### Requirements
- A Linux host with Docker + Docker Compose
- The host running in a **privileged** container with `NET_ADMIN` (Routehouse creates interfaces and manipulates routing/nftables — hence `privileged: true` in the compose file)

### 1. Clone and build

```bash
git clone https://github.com/jperz/routehouse.git
cd routehouse
```

### 2. Configure networking

Edit [docker-compose.yml](docker-compose.yml) for your environment. The sample uses a **macvlan** so the box gets its own IP directly on your LAN (recommended — clients reach it like any other host):

```yaml
lan:
  driver: macvlan
  driver_opts:
    parent: bond0                 # your host's LAN-facing interface
  ipam:
    config:
      - subnet: 192.168.10.0/24
        gateway: 192.168.10.1
```

Set a free LAN address for the container under `services.routehouse.networks.lan.ipv4_address`.

### 3. Add SSH keys for the tunnel user

The SSH jump user is **key-only** (no password, no shell). Drop authorized public keys onto the data volume before first start:

```bash
mkdir -p data/ssh
cat ~/.ssh/id_ed25519.pub >> data/ssh/authorized_keys
```

### 4. Launch

```bash
docker compose up -d --build
```

Open the dashboard at **`http://<box-ip>:3100`**.

---

## Configuring a VPN

Each VPN is one JSON file in [data/vpns/](data/vpns/). The filename (minus `.json`) is the VPN's name. Start from the samples — `sample.json` (OpenConnect), `sample_openvpn.json`, `sample_ipsec.json`, `sample_ipsec_xauthpsk.json`, `sample_ipsec_site2site.json` — or create one in the web UI.

### Common fields

```jsonc
{
  "type": "openconnect",                 // openconnect | openvpn | ipsec
  "interface_id": 42,                    // unique per VPN — becomes tun42 + table 42
  "log_file": "../data/logs/acme.log",
  "pid_file":  "../data/run/acme.pid",
  "debug": false,

  "additional_domains": ["acme.intern"], // resolved via THIS VPN's DNS only
  "manual_routes": ["172.27.104.0/24"],  // the ONLY traffic sent into this tunnel
  "exported_routes": [],                 // optional: announce to LAN via RIPv2
  "keepalive": [
    { "type": "ping", "target": "host.acme.intern", "interval": 120 }
  ],
  "up_cmds":   [],                       // run after connect (e.g. DNAT rules)
  "down_cmds": []                        // run on disconnect
}
```

The two fields that deliver the security story:
- **`manual_routes`** — the allow-list of destinations that enter this tunnel. Keep it tight.
- **`additional_domains`** — domains forwarded to this VPN's resolver and nowhere else (split DNS, no leaks).

### Per-protocol block

<details>
<summary><b>OpenConnect</b> (AnyConnect / Cisco / Juniper)</summary>

```jsonc
"openconnect": {
  "server": "vpn.acme.com",
  "username": "user.name@acme.com",
  "password": "secret",
  "protocol": "anyconnect",
  "config_file": "/etc/openconnect.cfg",
  "additional_args": ""
}
```
</details>

<details>
<summary><b>OpenVPN</b></summary>

```jsonc
"openvpn": {
  "config_file": "/data/vpns/acme.ovpn",
  "username": "myuser",
  "password": "mypassword",
  "additional_args": ""
}
```
</details>

<details>
<summary><b>IPsec / IKEv2 — EAP road-warrior</b></summary>

```jsonc
"ipsec": {
  "mode": "roadwarrior",
  "remote_gateway": "vpn.acme.com",
  "auth_type": "eap",
  "local_id": "user@acme.com",
  "remote_id": "vpn.acme.com",
  "eap_username": "myuser",
  "eap_password": "mypassword",
  "virtual_ip": true
}
```
</details>

<details>
<summary><b>IPsec / IKEv1 — XAuth + PSK</b> (typical Cisco group VPN)</summary>

```jsonc
"ipsec": {
  "mode": "roadwarrior",
  "remote_gateway": "vpn.acme.com",
  "auth_type": "xauth-psk",
  "local_id": "mygroupname",
  "psk": "groupsharedsecret",
  "xauth_username": "myuser",
  "xauth_password": "mypassword",
  "aggressive": true,
  "virtual_ip": true
}
```
</details>

<details>
<summary><b>IPsec — site-to-site (PSK)</b></summary>

```jsonc
"ipsec": {
  "mode": "site-to-site",
  "remote_gateway": "gateway.acme.com",
  "auth_type": "psk",
  "psk": "sharedsecret",
  "remote_subnets": ["10.0.0.0/8", "192.168.100.0/24"],
  "dns_server": "10.0.0.53"
}
```
</details>

---

## Using it

### Web dashboard — `http://<box-ip>:3100`
Start/stop each VPN, see live status and type, edit configs inline, tail per-VPN logs, and enable/disable the front-end services (Squid, SOCKS5, BIRD, SSH).

### Command line (inside the container)
```bash
docker exec -it routehouse vpn.sh status          # list all VPNs + state
docker exec -it routehouse vpn.sh start acme       # bring up data/vpns/acme.json
docker exec -it routehouse vpn.sh stop  acme       # tear it down + clean up
```

### Reaching internal hosts from your machines

**HTTP/HTTPS — point your browser or tool at the proxy:**
```bash
curl -x http://<box-ip>:3128 https://intranet.acme.intern
```

**Anything TCP — via SOCKS5:**
```bash
curl --socks5-hostname <box-ip>:1080 https://intranet.acme.intern
```

**SSH jump host — tunnel straight to an internal box:**
```bash
ssh -J tunnel@<box-ip>:22 admin@10.0.0.5
# or a forwarded port:
ssh -N -L 5901:vnc.acme.intern:5901 tunnel@<box-ip>
```

In every case Routehouse decides — by destination IP or domain — which tunnel the traffic belongs to, and sends it there and only there.

---

## Project layout

| Path | What |
|---|---|
| [bin/](bin/) | `vpn.sh` (lifecycle), protocol drivers, watchdog, keepalive, web server |
| [configs/](configs/) | Baked-in service configs (dnsmasq, squid, dante, bird, strongSwan, sshd) |
| [data/vpns/](data/vpns/) | Your VPN definitions (one JSON each) + samples |
| [data/](data/) | Runtime volume: logs, pids, generated dnsmasq/bird/squid fragments |
| [web/](web/) | Dashboard UI |
| [Dockerfile](Dockerfile) · [docker-compose.yml](docker-compose.yml) | Build & run |

---

## Security notes

- The container runs **privileged** — it manages kernel networking. Run it on a host you trust and keep the management ports (`3100`, `3128`, `1080`, `22`) on your LAN, not the public internet.
- The SSH tunnel user has **no shell and no password** — port-forwarding only.
- Credentials live in the VPN JSON files on the data volume; protect that directory and keep it out of git (the provided [.gitignore](.gitignore) already excludes real configs, logs and pids).

---

## License

Released under the [MIT License](LICENSE) © Jakob Perz.
