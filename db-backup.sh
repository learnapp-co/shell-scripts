#!/bin/bash
set -euo pipefail

# Same PATH as typical /etc/cron.d so `aws` is found when installed to /usr/local/bin
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# Runs mongodump from the mongo Docker container using the same credentials
# as mongo-dev-setup.sh (written to CREDENTIAL_FILE on first provisioning).

readonly CONTAINER_NAME="${CONTAINER_NAME:-mongo}"
readonly CREDENTIAL_FILE="${CREDENTIAL_FILE:-/root/mongo-credentials.txt}"
readonly BACKUP_DIR="${BACKUP_DIR:-/var/backups/mongodb}"
# Optional: e.g. s3://my-bucket/mongodb/daily/
readonly S3_BACKUP_URI="${S3_BACKUP_URI:-}"
readonly AWS_REGION="${AWS_REGION:-}"
# Set to 1 to keep the local .archive.gz after a successful S3 upload (default: remove to save disk)
readonly KEEP_LOCAL_BACKUP_AFTER_S3="${KEEP_LOCAL_BACKUP_AFTER_S3:-0}"

log() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
}

if [ ! -f "$CREDENTIAL_FILE" ]; then
  log "ERROR: Missing $CREDENTIAL_FILE (run mongo-dev-setup.sh first)"
  exit 1
fi

# shellcheck source=/dev/null
. "$CREDENTIAL_FILE"

if [ -z "${MONGO_USER:-}" ] || [ -z "${MONGO_PASS:-}" ]; then
  log "ERROR: MONGO_USER and MONGO_PASS must be set in $CREDENTIAL_FILE"
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  log "ERROR: Docker is not reachable (is it running?)."
  exit 1
fi

state=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo missing)
if [ "$state" != "running" ]; then
  log "ERROR: Container '$CONTAINER_NAME' not running (state=$state)."
  exit 1
fi

mkdir -p "$BACKUP_DIR"
# Local wall time, e.g. mongo-30-04-2026-14-35-22.archive.gz
stamp="$(date +%d-%m-%Y-%H-%M-%S)"
outfile="$BACKUP_DIR/mongo-${stamp}.archive.gz"

log "Starting backup → $outfile"

docker exec "$CONTAINER_NAME" mongodump \
  --username="$MONGO_USER" \
  --password="$MONGO_PASS" \
  --authenticationDatabase=admin \
  --gzip \
  --archive \
  >"$outfile"

backup_size="$(du -h "$outfile" | awk '{ print $1 }')"
log "Backup finished ($backup_size)"

if [ -n "$S3_BACKUP_URI" ]; then
  if ! command -v aws >/dev/null 2>&1; then
    log "ERROR: S3_BACKUP_URI is set but aws CLI is not installed (apt install awscli -y)."
    exit 1
  fi
  if [[ ! "$S3_BACKUP_URI" =~ ^s3://[^/[:space:]]+ ]]; then
    log "ERROR: S3_BACKUP_URI must start with s3://bucket[/prefix/]"
    exit 1
  fi

  remote="${S3_BACKUP_URI%/}/$(basename "$outfile")"
  log "Uploading to ${remote}"

  aws_args=(s3 cp "$outfile" "$remote" --only-show-errors --sse AES256)
  if [ -n "$AWS_REGION" ]; then
    aws_args+=(--region "$AWS_REGION")
  fi
  aws "${aws_args[@]}"

  log "S3 upload complete"
  if [[ "${KEEP_LOCAL_BACKUP_AFTER_S3}" != "1" ]]; then
    rm -f "$outfile"
    log "Removed local archive after S3 upload ($(basename "$outfile"))"
  else
    log "KEEP_LOCAL_BACKUP_AFTER_S3=1 — keeping local file $outfile"
  fi
else
  log "S3_BACKUP_URI is empty — skipping S3 upload (export it or set in /etc/cron.d/mongo-backup above the job line)."
fi

log "Done"
