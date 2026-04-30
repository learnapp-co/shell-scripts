#!/bin/bash
set -euo pipefail

# Copies db-backup.sh to /usr/local/sbin and writes /etc/cron.d/mongo-backup.
# Must run as root. Default cron time is 22:30 UTC (= 04:00 IST); assumes the host runs cron in UTC (typical EC2).

readonly SCRIPT_TARGET="/usr/local/sbin/db-backup.sh"
readonly CRON_FRAGMENT="/etc/cron.d/mongo-backup"

usage() {
  cat <<USAGE
Installs a daily root cron job that runs db-backup.sh.

Usage:
  sudo bash $0 [PATH_TO_db-backup.sh]

If PATH is omitted, uses BACKUP_SCRIPT env or db-backup.sh next to this installer.

Environment (optional):
  BACKUP_SCRIPT    Path to db-backup.sh (alternative to first argument)
  CRON_SCHEDULE    Five cron fields (default: 30 22 * * * = 04:00 IST when system time is UTC)
  S3_BACKUP_URI    If set, embedded in cron fragment for each backup run
  AWS_REGION       If set, embedded in cron fragment
  SKIP_AWSCLI_INSTALL Set to 1 to skip apt install of aws CLI (Ubuntu)

Examples:
  sudo bash $0
  sudo bash $0 /opt/shell-scripts/db-backup.sh
  sudo env S3_BACKUP_URI=s3://bucket/prefix/ AWS_REGION=us-east-1 bash $0
USAGE
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

ensure_aws_cli() {
  if [[ "${SKIP_AWSCLI_INSTALL:-0}" == "1" ]]; then
    return 0
  fi
  if command -v aws >/dev/null 2>&1; then
    return 0
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    echo 'ERROR: aws CLI not installed and apt-get missing. Install aws manually (see README) or pass SKIP_AWSCLI_INSTALL=1.' >&2
    exit 1
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y awscli

}

ensure_aws_cli

installer_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
default_src="${installer_dir}/db-backup.sh"
src="${1:-${BACKUP_SCRIPT:-$default_src}}"

if [[ ! -f "$src" ]]; then
  echo "ERROR: Backup script not found: $src" >&2
  exit 1
fi

if command -v realpath >/dev/null 2>&1; then
  src="$(realpath "$src")"
else
  src="$(readlink -f "$src" || echo "$src")"
fi

schedule="${CRON_SCHEDULE:-30 22 * * *}"
nfields="$(awk '{print NF}' <<<"$schedule")"
if [[ "$nfields" -ne 5 ]]; then
  echo "ERROR: CRON_SCHEDULE must be exactly 5 cron fields (e.g. 30 22 * * *). Got NF=$nfields" >&2
  exit 1
fi

mkdir -p /usr/local/sbin
cp -f "$src" "$SCRIPT_TARGET"
chmod +x "$SCRIPT_TARGET"

umask 022
{
  printf '%s\n' \
    '# Installed by mongo-backup-install-cron.sh (edit or re-run installer to change).' \
    '# Default below: 22:30 UTC = 04:00 IST (India has no DST).' \
    'SHELL=/bin/bash' \
    'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
  if [[ -n "${S3_BACKUP_URI:-}" ]]; then
    printf 'S3_BACKUP_URI=%s\n' "$S3_BACKUP_URI"
  fi
  if [[ -n "${AWS_REGION:-}" ]]; then
    printf 'AWS_REGION=%s\n' "$AWS_REGION"
  fi
  printf '%s root %s >> /var/log/mongo-backup.log 2>&1\n' "$schedule" "$SCRIPT_TARGET"
} >"$CRON_FRAGMENT"
chmod 644 "$CRON_FRAGMENT"

systemctl reload cron 2>/dev/null || service cron reload

printf 'Installed: %s → %s\nCron: %s (schedule %s; default is 22:30 UTC = 04:00 IST if host is UTC)\nLogs: /var/log/mongo-backup.log\n' \
  "$src" "$SCRIPT_TARGET" "$CRON_FRAGMENT" "$schedule"
