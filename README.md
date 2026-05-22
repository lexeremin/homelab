# Homelab Manager

Modular homelab management scripts. Everything runs in Docker — no host packages required.

## Modules

### AmneziaWG

[AmneziaWireGuard](https://hub.docker.com/r/amneziavpn/amneziawg-go) — WireGuard with DPI obfuscation for networks that block plain WireGuard.

**Prerequisites:**
- `amneziawg` kernel module on the host — the container creates a kernel network interface (`ip link add type amneziawg`), which requires the module to be loaded
  - Build from: https://github.com/amnezia-vpn/amneziawg-linux-kernel-module
- Inbound UDP port forwarded to homelab

### Headscale

[Headscale](https://headscale.net) — self-hosted Tailscale control plane for a private mesh network between homelab nodes.

**Prerequisites:**
- A domain or IP reachable by all nodes (`SERVER_URL` in `.env`)

## Setup

```bash
cp .env.example .env
# Edit .env — fill in the relevant section(s)
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
./homelab.sh headscale setup         # First-time setup
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
| `lib/common.sh` | Shared helpers |
| `lib/docker.sh` | Docker auto-detection |
| `modules/amnezia.sh` | AmneziaWG server + client management |
| `modules/headscale.sh` | Headscale control plane management |
| `.env.example` | Config template — copy to `.env` |
| `.env` | Your config + generated credentials (gitignored) |
| `homelab_NAME_DATE.conf` | Generated client configs (gitignored) |

## Security notes

- `.env` and `*.conf` are gitignored — never commit them
- Each device gets its own key pair — revoke per device with `remove-client`
- The server never stores client private keys
