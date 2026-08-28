# Ubuntu VM on Cloudflare Containers

Run a nested Ubuntu 24.04 server (QEMU) inside a [Cloudflare Container](https://developers.cloudflare.com/containers/), with a simple status page and optional Tailscale for SSH access.

## What this does

| Layer | Role |
| --- | --- |
| Cloudflare Worker (`src/index.ts`) | Routes HTTP to container instances |
| Container (`Dockerfile`) | Host: status page + QEMU + Tailscale |
| Nested VM | Ubuntu 24.04 cloud image (SSH, Node 20, etc.) |

The container serves `index.html` on **port 7860** (Cloudflare `defaultPort`). The nested VM is reached over **Tailscale** (recommended) or container-local SSH on port 2222.

## Cloudflare resource limits (important)

Cloudflare Containers max out at roughly **4 vCPU / 12 GiB RAM / 20 GB disk** (`standard-4`). Defaults are therefore tuned down from a bare-metal setup:

| Setting | Value | Notes |
| --- | --- | --- |
| `instance_type` | `standard-4` | Max CF size |
| `VM_RAM` | `8192` | Leaves headroom for QEMU host |
| `VM_SMP` | `4` | Matches vCPU |
| `VM_DISK_SIZE` | `10G` | Fits in 20 GB instance disk |
| KVM | usually unavailable | Falls back to TCG (slower boot) |

## Getting Started

```bash
npm install
```

### Secrets (optional but recommended)

```bash
npx wrangler secret put TS_AUTHKEY        # Tailscale auth key
npx wrangler secret put VM_ROOT_PASSWORD  # nested VM root password
npx wrangler secret put VM_SSH_PUBKEY     # optional SSH public key
```

Plain vars (already in `wrangler.jsonc`):

- `TS_HOSTNAME` – Tailscale hostname
- `VM_NAME` – nested VM hostname

### Local dev

```bash
npm run dev
```

Open [http://localhost:8787](http://localhost:8787). Note: nested QEMU is heavy; local Docker must be running and you need enough RAM.

### Deploy

```bash
npm run deploy
```

First build downloads the Ubuntu cloud image and is slow; later deploys reuse layer cache.

## HTTP routes

| Path | Behavior |
| --- | --- |
| `GET /` | Lists endpoints |
| `GET /container/<ID>` | Dedicated container per ID (status page) |
| `GET /lb` | Random among a small pool |
| `GET /singleton` | One shared instance |

Example:

```text
https://<your-worker>.workers.dev/container/demo
```

You should see **Server is running**.

## Accessing the nested Ubuntu VM

1. Set `TS_AUTHKEY` so the container joins your tailnet on boot.
2. From any device on the tailnet:

   ```bash
   ssh root@<TS_HOSTNAME-or-tailscale-ip>
   ```

   Default password is `changeme` unless you set `VM_ROOT_PASSWORD`.

> Cloudflare HTTP routing only reaches the status page (7860). It does **not** expose nested SSH (2222) to the public Internet — use Tailscale.

## Project layout

```text
Dockerfile          # QEMU host + Tailscale + start-all
index.html          # Status page (port 7860)
src/index.ts        # Worker + Container class
wrangler.jsonc      # standard-4 instance, bindings
```

## Learn more

- [Cloudflare Containers](https://developers.cloudflare.com/containers/)
- [Container class](https://developers.cloudflare.com/containers/container-class/)
- [Instance types & limits](https://developers.cloudflare.com/containers/platform-details/limits/)
