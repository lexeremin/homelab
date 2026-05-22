# Homelab Manager

Modular homelab management scripts for [AmneziaWireGuard](https://hub.docker.com/r/amneziavpn/amneziawg-go) VPN and [Headscale](https://headscale.net) control plane. Everything runs in Docker — no host-level packages required.

## Traffic flow (AmneziaWG)

```
Device → AmneziaWG (homelab) → OpenWrt → Podkop/sing-box → AmneziaVPN → Internet
```

Podkop on OpenWrt handles domain-based routing: blocked services (YouTube, Telegram, Discord) go through AmneziaVPN tunnel, everything else goes direct. DNS must point to OpenWrt (`192.168.1.1`) so sing-box fakeip routing works correctly.

## Requirements

- Ubuntu 24.04 on homelab
- Docker installed
- **AmneziaWG only:** `amneziawg` kernel module built and installed on host
  - Build from: https://github.com/amnezia-vpn/amneziawg-linux-kernel-module
- OpenWrt router with Podkop configured
- Port `51820/UDP` forwarded from ISP router → OpenWrt → homelab

## Setup

```bash
cp .env.example .env
# Edit .env — set ENDPOINT, SERVER_PORT, HOST_IFACE at minimum
chmod +x homelab.sh
```

## Usage

```bash
# AmneziaWG
./homelab.sh amnezia setup           # First-time server setup
./homelab.sh amnezia add-client      # Add a client (prompts for name)
./homelab.sh amnezia remove-client   # Remove a client (interactive list)
./homelab.sh amnezia status          # Show container state + peers
./homelab.sh amnezia remove-setup    # Full teardown

# Headscale
./homelab.sh headscale setup         # First-time setup (requires SERVER_URL in .env)
./homelab.sh headscale create-user   # Create a Tailscale user
./homelab.sh headscale list-nodes    # List registered nodes
./homelab.sh headscale register-node # Register a node by key
./homelab.sh headscale status        # Show container state + node list
./homelab.sh headscale remove-setup  # Full teardown
```

Run without a subcommand for an interactive menu:

```bash
./homelab.sh
./homelab.sh amnezia
./homelab.sh headscale
```

Each AmneziaWG client gets a config file `homelab_NAME_YYYY_MM_DD.conf`. Import it into the [Amnezia app](https://amnezia.org). Delete after importing — it contains the private key.

## Files

| Path | Description |
|------|-------------|
| `homelab.sh` | Entry point — sources libs and modules |
| `lib/common.sh` | Shared helpers (die, step, confirm, env_set, …) |
| `lib/docker.sh` | Docker auto-detection (`$DOCKER`) |
| `modules/amnezia.sh` | AmneziaWG server + client management |
| `modules/headscale.sh` | Headscale control plane management |
| `.env.example` | Config template — copy to `.env` |
| `.env` | Your config + generated credentials (gitignored) |
| `homelab_NAME_DATE.conf` | Generated client configs (gitignored) |

## Security notes

- `.env` and `*.conf` are gitignored — never commit them
- Each device gets its own key pair — revoke per device with `remove-client`
- The server never stores client private keys
