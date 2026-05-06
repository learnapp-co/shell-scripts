#!/bin/bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

readonly CONTAINER_NAME="${CONTAINER_NAME:-mongo}"
readonly CREDENTIAL_FILE="${CREDENTIAL_FILE:-/root/mongo-credentials.txt}"
readonly BACKUP_DIR="${BACKUP_DIR:-/var/backups/mongodb}"

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

S3_BACKUP_URI="${S3_BACKUP_URI:-}"
AWS_REGION="${AWS_REGION:-}"
KEEP_LOCAL_BACKUP_AFTER_S3="${KEEP_LOCAL_BACKUP_AFTER_S3:-0}"

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

log "Backup finished ($(du -h "$outfile" | awk '{ print $1 }'))"

if [ -n "$S3_BACKUP_URI" ]; then
  if ! command -v aws >/dev/null 2>&1; then
    log "ERROR: S3_BACKUP_URI is set but aws CLI is not installed"
    exit 1
  fi
  if [[ ! "$S3_BACKUP_URI" =~ ^s3://[^/[:space:]]+ ]]; then
    log "ERROR: S3_BACKUP_URI must start with s3://bucket[/prefix/]"
    exit 1
  fi

  remote="${S3_BACKUP_URI%/}/$(basename "$outfile")"
  log "Uploading to ${remote}"

  aws ${AWS_REGION:+--region "$AWS_REGION"} s3 cp "$outfile" "$remote" --only-show-errors --sse AES256

  log "S3 upload complete"
  if [ "$KEEP_LOCAL_BACKUP_AFTER_S3" != 1 ]; then
    rm -f "$outfile"
    log "Removed local file $(basename "$outfile")"
  else
    log "Keeping local file (KEEP_LOCAL_BACKUP_AFTER_S3=1)"
  fi
else
  log "No S3_BACKUP_URI — local archive only"
fi

log "Done"
