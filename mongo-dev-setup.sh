#!/bin/bash
set -eux

# -----------------------------
# 1. Detect secondary EBS (works on both Nitro/nvme and Xen/xvd)
# -----------------------------
ROOT_DEV=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)")
DEVICE=$(lsblk -dpno NAME,TYPE | awk '$2=="disk"{print $1}' | grep -v "/dev/${ROOT_DEV}$" | head -n 1)
[ -n "$DEVICE" ] || { echo "No secondary EBS found"; exit 1; }

echo "Detected device: $DEVICE"

# -----------------------------
# 2. Mount EBS (DO NOT FORMAT)
# -----------------------------
mkdir -p /data/db

# Mount only if not already mounted (idempotent)
mountpoint -q /data/db || mount "$DEVICE" /data/db || true

# -----------------------------
# 3. Verify mount
# -----------------------------
if mountpoint -q /data/db; then
  echo "EBS mounted successfully"
else
  echo "Mount failed, exiting"
  exit 1
fi

# -----------------------------
# 4. Fix permissions for MongoDB
# -----------------------------
chown -R 999:999 /data/db

# -----------------------------
# 5. Persist mount (fstab)
# -----------------------------
UUID=$(blkid -s UUID -o value "$DEVICE")

grep -q "UUID=$UUID" /etc/fstab || \
  echo "UUID=$UUID /data/db ext4 defaults,nofail 0 2" >> /etc/fstab

# -----------------------------
# 6. Install Docker (official)
# -----------------------------
apt-get update
apt-get install -y ca-certificates curl gnupg

install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
gpg --dearmor -o /etc/apt/keyrings/docker.gpg

chmod a+r /etc/apt/keyrings/docker.gpg

echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo $VERSION_CODENAME) stable" \
> /etc/apt/sources.list.d/docker.list

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable docker
systemctl start docker

# -----------------------------
# 7. Start MongoDB 8 container
# -----------------------------
# Disable command tracing while handling secrets (avoid leaking to cloud-init logs)
set +x

# Generate credentials only once; reuse on subsequent boots so auth keeps working
if [ ! -f /root/mongo-credentials.txt ]; then
  umask 077
  MONGO_USER="admin"
  MONGO_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 32)
  cat > /root/mongo-credentials.txt <<EOF
MONGO_USER="$MONGO_USER"
MONGO_PASS="$MONGO_PASS"
EOF
  chmod 600 /root/mongo-credentials.txt
fi
. /root/mongo-credentials.txt

if ! docker ps -a --format '{{.Names}}' | grep -q '^mongo$'; then
  docker run -d \
    --name mongo \
    -p 27017:27017 \
    -v /data/db:/data/db \
    -e MONGO_INITDB_ROOT_USERNAME="$MONGO_USER" \
    -e MONGO_INITDB_ROOT_PASSWORD="$MONGO_PASS" \
    --restart unless-stopped \
    mongo:8 \
    --auth --wiredTigerCacheSizeGB 2
fi

set -x

# -----------------------------
# 8. Done
# -----------------------------
echo "MongoDB setup complete"