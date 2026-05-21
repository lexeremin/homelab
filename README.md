# Homelab AmneziaWG VPN

Full-tunnel VPN to homelab via [AmneziaWireGuard](https://hub.docker.com/r/amneziavpn/amneziawg-go) — a WireGuard implementation with DPI obfuscation. All client traffic routes through homelab → OpenWrt (Podkop) for transparent DPI bypass.

## Traffic flow

```
Device → AmneziaWG (homelab) → OpenWrt → Podkop/sing-box → AmneziaVPN → Internet
```

Podkop on OpenWrt handles domain-based routing: blocked services (YouTube, Telegram, Discord) go through AmneziaVPN tunnel, everything else goes direct. DNS must point to OpenWrt (`192.168.1.1`) so sing-box fakeip routing works correctly.

## Requirements

- Ubuntu 24.04 on homelab
- Docker installed
- `wireguard-tools` (`apt install wireguard-tools`)
- OpenWrt router with Podkop configured
- Port `51820/UDP` forwarded from ISP router → OpenWrt → homelab

## Setup

```bash
cp .env.example .env
# Edit .env — set ENDPOINT and SERVER_PORT at minimum
chmod +x amnezia-setup.sh
./amnezia-setup.sh
```

## Usage

Run without arguments for interactive menu:

```
./amnezia-setup.sh

  ┌─────────────────────────────┐
  │     AmneziaWG Manager       │
  ├─────────────────────────────┤
  │  1) Setup server            │
  │  2) Add client              │
  │  3) Remove client           │
  │  4) Remove setup            │
  │  0) Exit                    │
  └─────────────────────────────┘
```

Or call subcommands directly:

```bash
./amnezia-setup.sh setup           # First-time server setup
./amnezia-setup.sh add-client      # Add a client (prompts for name)
./amnezia-setup.sh remove-client   # Remove a client (interactive list)
./amnezia-setup.sh remove-setup    # Full teardown
```

Each client gets a config file named `homelab_NAME_YYYY_MM_DD.conf`. Import it into the [Amnezia app](https://amnezia.org) on your device. Delete the file after importing — it contains the private key.

## Files

| File | Description |
|------|-------------|
| `.env.example` | Config template — copy to `.env` |
| `.env` | Your config + generated credentials (gitignored) |
| `amnezia-setup.sh` | Setup and management script |
| `homelab_NAME_DATE.conf` | Generated client configs (gitignored) |

## Security notes

- `.env` and `*.conf` are gitignored — never commit them
- Each device gets its own key pair — revoke per device with "Remove client"
- The server never stores client private keys
