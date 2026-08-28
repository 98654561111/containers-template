# syntax=docker/dockerfile:1

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    VM_WORKDIR=/workspace \
    VM_NAME=ubuntu-vm \
    UBUNTU_RELEASE=noble \
    VM_RAM=8192 \
    VM_SMP=4 \
    VM_SSH_PORT=2222 \
    VM_ROOT_PASSWORD=changeme \
    VM_DISK_SIZE=10G \
    TS_HOSTNAME=modelscope-ubuntu \
    TS_STATE_DIR=/tmp/tailscale \
    STATUS_PORT=7860

# 安裝外層需要的工具
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash ca-certificates wget curl xz-utils gnupg lsb-release \
    qemu-system-x86 qemu-utils cloud-image-utils \
    openssh-client coreutils ovmf \
    python3 \
    && rm -rf /var/lib/apt/lists/*

# 安裝 Tailscale（官方 apt 倉庫）
RUN curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg \
        -o /usr/share/keyrings/tailscale-archive-keyring.gpg \
    && curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list \
        -o /etc/apt/sources.list.d/tailscale.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends tailscale \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

# 預先下載 Ubuntu 24.04 cloud image
RUN wget -O "/workspace/noble-server-cloudimg-amd64.img" \
    "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"

# 複製狀態頁面
COPY index.html /workspace/www/index.html

# 啟動腳本
RUN cat > /usr/local/bin/start-all <<'EOF' && chmod +x /usr/local/bin/start-all
#!/usr/bin/env bash
set -euo pipefail
cd "${VM_WORKDIR:-/workspace}"

UBUNTU_RELEASE="${UBUNTU_RELEASE:-noble}"
VM_NAME="${VM_NAME:-ubuntu-vm}"
VM_RAM="${VM_RAM:-8192}"
VM_SMP="${VM_SMP:-4}"
VM_SSH_PORT="${VM_SSH_PORT:-2222}"
VM_ROOT_PASSWORD="${VM_ROOT_PASSWORD:-changeme}"
VM_SSH_PUBKEY="${VM_SSH_PUBKEY:-}"
VM_DISK_SIZE="${VM_DISK_SIZE:-10G}"
TS_AUTHKEY="${TS_AUTHKEY:-}"
TS_HOSTNAME="${TS_HOSTNAME:-modelscope-ubuntu}"
TS_STATE_DIR="${TS_STATE_DIR:-/tmp/tailscale}"
STATUS_PORT="${STATUS_PORT:-7860}"

BASE_IMAGE="${UBUNTU_RELEASE}-server-cloudimg-amd64.img"
BASE_PATH="${VM_WORKDIR}/${BASE_IMAGE}"
DISK_PATH="${VM_WORKDIR}/${VM_NAME}.qcow2"
SEED_PATH="${VM_WORKDIR}/seed.iso"
WWW_DIR="${VM_WORKDIR}/www"

mkdir -p "${TS_STATE_DIR}" "${WWW_DIR}"

echo "===================================================="
echo " Ubuntu Host Container + QEMU + Ubuntu Server + Tailscale"
echo "===================================================="

echo "[1/7] 啟動 HTTP 狀態頁面 (port ${STATUS_PORT})..."
python3 -m http.server "${STATUS_PORT}" --directory "${WWW_DIR}" --bind 0.0.0.0 >/tmp/httpd.log 2>&1 &
HTTP_PID=$!
echo "  → HTTP Server PID: ${HTTP_PID}"

echo "[2/7] 檢查 Ubuntu cloud image..."
if [ ! -f "${BASE_PATH}" ]; then
  wget -O "${BASE_PATH}" "https://cloud-images.ubuntu.com/${UBUNTU_RELEASE}/current/${BASE_IMAGE}"
else
  echo "已存在，跳過"
fi

echo "[3/7] 準備 VM 磁碟..."
if [ ! -f "${DISK_PATH}" ]; then
  qemu-img create -f qcow2 -b "${BASE_PATH}" -F qcow2 "${DISK_PATH}" "${VM_DISK_SIZE}"
fi

echo "[4/7] 設定固定磁碟大小: ${VM_DISK_SIZE}"
qemu-img resize "${DISK_PATH}" "${VM_DISK_SIZE}" || true
qemu-img info "${DISK_PATH}" | grep 'virtual size' || true

echo "[5/7] 生成 cloud-init..."
cat > user-data <<USERDATA
#cloud-config
hostname: ${VM_NAME}
manage_etc_hosts: true
disable_root: false
ssh_pwauth: true
chpasswd:
  expire: false
  users:
    - name: root
      password: ${VM_ROOT_PASSWORD}
      type: text
users:
  - name: root
    lock_passwd: false
    shell: /bin/bash
USERDATA

if [ -n "${VM_SSH_PUBKEY}" ]; then
cat >> user-data <<USERDATA
    ssh_authorized_keys:
      - ${VM_SSH_PUBKEY}
USERDATA
fi

cat >> user-data <<'USERDATA'
package_update: true
package_upgrade: false
packages:
  - openssh-server
  - cloud-guest-utils
  - parted
  - sudo
  - curl
  - wget
  - git
  - htop
  - ca-certificates
  - gnupg
  - lsb-release
  - build-essential
  - qemu-guest-agent

growpart:
  mode: auto
  devices: ['/']
resize_rootfs: true

runcmd:
  - sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  - sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - systemctl enable --now ssh qemu-guest-agent
  - growpart /dev/vda 1 || true
  - resize2fs /dev/vda1 || true
  - curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  - apt-get install -y nodejs
  - npm install -g @google/gemini-cli || true
  - node -v > /root/versions.log 2>&1
  - npm -v >> /root/versions.log 2>&1

final_message: "VM ready! SSH: ssh root@<host> -p 2222"
USERDATA

cat > meta-data <<METADATA
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
METADATA

cloud-localds "${SEED_PATH}" user-data meta-data

echo "[6/7] 啟動 Tailscale..."
if [ -n "${TS_AUTHKEY}" ]; then
  tailscaled --tun=userspace-networking \
    --state="${TS_STATE_DIR}/tailscaled.state" \
    --socket=/tmp/tailscaled.sock >/tmp/tailscaled.log 2>&1 &
  for i in $(seq 1 20); do
    [ -S /tmp/tailscaled.sock ] && break
    sleep 1
  done
  tailscale --socket=/tmp/tailscaled.sock up \
    --authkey="${TS_AUTHKEY}" \
    --hostname="${TS_HOSTNAME}" \
    --accept-dns=false \
    --reset
  tailscale --socket=/tmp/tailscaled.sock ip -4 || true
else
  echo "  → 未設定 TS_AUTHKEY，跳過 Tailscale"
fi

echo "[7/7] 啟動 QEMU..."
if [ -c /dev/kvm ]; then
  echo "  → KVM 加速可用"
  QEMU_ACCEL_ARGS=(-machine q35,accel=kvm -cpu host)
else
  echo "  → 無 KVM，使用 TCG 多執行緒模式"
  QEMU_ACCEL_ARGS=(-machine q35 -accel tcg,thread=multi -cpu max)
fi

echo ""
echo "===================================================="
echo " Status Page: http://0.0.0.0:${STATUS_PORT}"
echo " VM SSH:      ssh root@localhost -p ${VM_SSH_PORT}"
echo "===================================================="
echo ""

exec qemu-system-x86_64 \
  "${QEMU_ACCEL_ARGS[@]}" \
  -smp "${VM_SMP}" \
  -m "${VM_RAM}" \
  -drive if=virtio,format=qcow2,file="${DISK_PATH}",discard=unmap \
  -drive if=virtio,format=raw,readonly=on,file="${SEED_PATH}" \
  -nic user,model=virtio-net-pci,hostfwd=tcp::"${VM_SSH_PORT}"-:22 \
  -device virtio-rng-pci \
  -nographic
EOF

EXPOSE 2222 7860
ENTRYPOINT ["/usr/local/bin/start-all"]
