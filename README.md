# shell-scripts

Operational scripts for this repo.

## `mongo-dev-setup.sh`

Sets up MongoDB in Docker on an Ubuntu machine that has a **separate**, **pre-formatted** (ext4) EBS volume attached for data.

### What it does

1. Finds the secondary disk (excluding the root volume — works on Nitro `nvme` and Xen `xvd` instances).
2. Mounts it at `/data/db` (idempotent) and adds a **single** `fstab` entry if missing.
3. Sets ownership on `/data/db` for the MongoDB container user (UID 999).
4. Installs Docker from the official repository and starts the service.
5. Creates `admin` + a random root password **once**, writes them to `/root/mongo-credentials.txt` (mode `600`), and starts a `mongo:8` container with `--auth` and a 2 GB WiredTiger cache.

Re-running the script is safe: it will not duplicate `fstab` lines, will not recreate the container if `mongo` already exists, and will not rotate the password (so existing data on the volume keeps working).

### Prerequisites

- Ubuntu (script uses `apt`).
- Run as **root** (or with `sudo`).
- **One** extra EBS volume attached, already formatted as **ext4** (the script does not format disks).
- The volume must be present before you run the script (attach it first if you run this manually).

### Credentials

After the first successful run:

```bash
sudo cat /root/mongo-credentials.txt
```

Use `MONGO_USER` and `MONGO_PASS` in your connection string (e.g. `mongodb://MONGO_USER:MONGO_PASS@host:27017/?authSource=admin`).

### Connection

MongoDB listens on **27017** on all interfaces (`-p 27017:27017`). Restrict access with a security group or firewall in production.

## `mongo-backup-daily.sh`

Creates a compressed **logical** backup (`mongodump` archive) of everything the root user can read. Intended to run daily from cron as **root** on the same host as Docker.

### Configuration (environment variables)

| Variable | Default | Meaning |
| -------- | ------- | ------- |
| `CONTAINER_NAME` | `mongo` | Docker container name |
| `CREDENTIAL_FILE` | `/root/mongo-credentials.txt` | Same file as provisioning |
| `BACKUP_DIR` | `/var/backups/mongodb` | Where `.archive.gz` files are written |
| `RETENTION_DAYS` | `14` | Delete **local** backups older than this many days |
| `S3_BACKUP_URI` | *(empty)* | If set, upload each backup with `aws s3 cp` (e.g. `s3://my-bucket/mongodb/daily/`) |
| `AWS_REGION` | *(empty)* | Passes `--region` to `aws` (omit if your default config is enough) |

### S3 upload

1. Install the AWS CLI on the instance (e.g. `sudo apt-get install -y awscli` on Ubuntu, or use [AWS’s install guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)).
2. Grant the instance an IAM role (or credentials) with **`s3:PutObject`** (and usually **`s3:PutObjectAcl`** if you rely on ACLs) on your bucket/prefix.
3. Set **`S3_BACKUP_URI`** to a prefix ending with `/` or not; the script normalizes it and uses the archive filename as the object key.

Objects are uploaded with **SSE-S3** server-side encryption (`AES256`). For long-term retention in S3, add a **bucket lifecycle rule** (the script does not delete objects in S3).

### Manual run

```bash
sudo /path/to/shell-scripts/mongo-backup-daily.sh
```

### Cron (daily at 02:15 UTC)

```bash
sudo cp /path/to/shell-scripts/mongo-backup-daily.sh /usr/local/sbin/mongo-backup-daily.sh
sudo tee /etc/cron.d/mongo-backup <<'EOF'
S3_BACKUP_URI=s3://YOUR-BUCKET/mongodb/daily/
AWS_REGION=us-east-1
15 2 * * * root /usr/local/sbin/mongo-backup-daily.sh >> /var/log/mongo-backup.log 2>&1
EOF
```

Adjust `S3_BACKUP_URI` / `AWS_REGION` or remove the lines you do not need. On EC2, prefer an **instance role** over long-lived access keys.

### Restore (on a host with `mongorestore`, e.g. another `mongo:8` container)

Use the password from `/root/mongo-credentials.txt` after copying the archive to the restore host:

```bash
mongorestore --gzip --archive=/path/to/mongo-YYYYMMDD-HHMMSS.archive.gz \
  --username=admin --password='…' --authenticationDatabase=admin
```
