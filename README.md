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

## `db-backup.sh`

Creates a compressed **logical** backup (`mongodump` archive) of everything the root user can read. Intended to run daily from cron as **root** on the same host as Docker. Local archives under `BACKUP_DIR` are **not** rotated by the script; configure **S3 lifecycle** (and optional local cleanup) yourself.

### Configuration (environment variables)

| Variable | Default | Meaning |
| -------- | ------- | ------- |
| `CONTAINER_NAME` | `mongo` | Docker container name |
| `CREDENTIAL_FILE` | `/root/mongo-credentials.txt` | Same file as provisioning |
| `BACKUP_DIR` | `/var/backups/mongodb` | Where `.archive.gz` files are written (not auto-deleted) |
| `S3_BACKUP_URI` | *(empty)* | If set, upload each backup with `aws s3 cp` (e.g. `s3://my-bucket/mongodb/daily/`) |
| `AWS_REGION` | *(empty)* | Passes `--region` to `aws` (omit if your default config is enough) |

Schedule daily runs with **`mongo-backup-install-cron.sh`** (separate file).

### S3 upload

1. **`mongo-backup-install-cron.sh`** installs **`aws`** if missing: it tries **`apt install awscli`** first, then falls back to **AWS CLI v2** from `https://awscli.amazonaws.com/` (needs **`curl`/`unzip`** from apt and outbound HTTPS). Skip all of that with **`SKIP_AWSCLI_INSTALL=1`** if you install the CLI yourself.
2. Grant the instance an IAM role (or credentials) with **`s3:PutObject`** (and usually **`s3:PutObjectAcl`** if you rely on ACLs) on your bucket/prefix.
3. Set **`S3_BACKUP_URI`** to a prefix ending with `/` or not; **`db-backup.sh`** uses the archive filename as the object key.

Objects are uploaded with **SSE-S3** server-side encryption (`AES256`). **Retention** should be handled with an S3 **lifecycle rule** (this script does not delete objects in S3 or on disk).

#### How **`aws`** gets permission (no keys in this repo)

The **`aws`** CLI picks credentials automatically (standard [credential chain](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-configure.html)):

1. **EC2 instance profile** (recommended): attach an IAM **role** to the instance (launch template / instance settings). Cron runs **`db-backup.sh`** as **`root`** on the **host**, so **`aws`** can read **temporary credentials** from the instance metadata endpoint—**no **`AWS_SECRET_ACCESS_KEY`** in cron**.
2. **Fallbacks** (manual / non‑EC2): environment variables (**`AWS_ACCESS_KEY_ID`** / **`AWS_SECRET_ACCESS_KEY`**), **`~/.aws/credentials`** (for **`root`**, that’s **`/root/.aws/credentials`**), or SSO / other configured profiles—only if present.

Attach a policy that allows upload to your backup prefix only, for example **`s3:PutObject`** (and **`s3:AbortMultipartUpload`** if you rely on multipart) on **`arn:aws:s3:::YOUR-BUCKET/mongodb/daily/*`**.

### Manual run

Local-only (no S3) unless you pass env on the same line:

```bash
sudo /path/to/shell-scripts/db-backup.sh
```

With S3 (**required** for uploads — the script does not read this from a file):

```bash
sudo env S3_BACKUP_URI="s3://YOUR-BUCKET/prefix/" AWS_REGION="ap-south-1" /path/to/shell-scripts/db-backup.sh
```

If backups stay on disk only, check **`/var/log/mongo-backup.log`** (or your cron log): the script now logs when **`S3_BACKUP_URI`** is empty. For cron, variables must appear **in** **`/etc/cron.d/mongo-backup`** **above** the schedule line (or re-run **`mongo-backup-install-cron.sh`** with **`S3_BACKUP_URI`** / **`AWS_REGION`** set).

## `mongo-backup-install-cron.sh`

Installs a **`root`** cron job in **`/etc/cron.d/mongo-backup`**, copies **`db-backup.sh`** to **`/usr/local/sbin/db-backup.sh`**, and reloads **`cron`**. If **`aws`** is missing, **`apt-get install awscli`** is run (**Ubuntu**/Debian with `apt-get`). Run once on the server **as root**. The default schedule is **`30 22 * * *`** (22:30 **UTC** ≈ **04:00 IST**). Cron uses the **host’s** timezone; EC2 Linux is usually UTC—if yours is not, override with **`CRON_SCHEDULE`**.

| Variable / arg | Default | Meaning |
| ---------------- | ------- | ------- |
| First argument | *(see below)* | Path to `db-backup.sh`; if omitted, uses `BACKUP_SCRIPT` or the copy next to this installer |
| `BACKUP_SCRIPT` | | Same as passing the path via env instead of argv |
| `CRON_SCHEDULE` | `30 22 * * *` | Minute hour DOM month weekday **in the machine’s local time** (default = 04:00 IST when TZ is UTC) |
| `S3_BACKUP_URI` | *(empty)* | If set, written into `/etc/cron.d/mongo-backup` for each backup run |
| `AWS_REGION` | *(empty)* | If set, written into the cron fragment |
| `SKIP_AWSCLI_INSTALL` | *(unset)* | Set to **`1`** to skip **`apt`** install when **`aws`** is missing |

```bash
sudo bash /path/to/shell-scripts/mongo-backup-install-cron.sh
sudo bash /path/to/shell-scripts/mongo-backup-install-cron.sh /custom/path/db-backup.sh
sudo env S3_BACKUP_URI=s3://YOUR-BUCKET/mongodb/daily/ AWS_REGION=us-east-1 \
  bash /path/to/shell-scripts/mongo-backup-install-cron.sh
```

Cron output: **`/var/log/mongo-backup.log`**. Edit `/etc/cron.d/mongo-backup` or re-run the installer to change schedule or S3. On EC2, prefer an instance role for **`aws`** instead of keys.

## Restore (mongorestore)

Use the password from `/root/mongo-credentials.txt` after copying the archive to the restore host:

```bash
mongorestore --gzip --archive=/path/to/mongo-YYYYMMDD-HHMMSS.archive.gz \
  --username=admin --password='…' --authenticationDatabase=admin
```
