# MinIO on Dokploy, with scheduled backups to Cloudflare R2

A hardened Docker Compose stack that runs MinIO (S3-compatible object storage) on
[Dokploy](https://dokploy.com). A backup sidecar copies your buckets to a
[Cloudflare R2](https://developers.cloudflare.com/r2/) bucket on a cron schedule. All
settings live in environment variables.

```
                 HTTPS (Let's Encrypt, via Dokploy's Traefik)
  s3.example.com ───────► minio :9000  (S3 API)       ┐
  console.example.com ──► minio :9001  (web console)  │  volume: minio-data
                                                      │
                          backup ── S3 API ──► minio  ┘
                             │  rclone, on BACKUP_SCHEDULE
                             └──────── HTTPS ────────► Cloudflare R2 bucket
```

| File | Purpose |
| --- | --- |
| [docker-compose.yml](docker-compose.yml) | The stack: `minio` and `backup` services |
| [.env.example](.env.example) | Every setting, with comments. Paste it into Dokploy |
| [backup/Dockerfile](backup/Dockerfile) | Backup image: official rclone plus supercronic |
| [backup/minio-backup.sh](backup/minio-backup.sh) | Backup, check and restore logic |

## About the MinIO image

MinIO Inc. stopped publishing community images and binaries in October 2025. It then
archived the `minio/minio` repository in 2026 and removed the `minio/minio` images from
Docker Hub. The last official image never got later security fixes.

This stack uses [`pgsty/silo`](https://github.com/pgsty/silo), the maintained
community fork that Dokploy's own MinIO template also moved to. It is a drop-in
replacement:

- The `MINIO_*` variables are the same.
- The `/data` on-disk format is the same, so existing volumes work.
- The full web console is still there.
- It still gets CVE fixes.

This stack uses the **distroless** variant. The image contains only the server binary,
with no shell and no package manager. It is pinned by digest.

## Security

Built in:

- **No host ports.** Both MinIO ports are only `expose`d to the container network.
  They are reachable only through Dokploy's Traefik, over HTTPS.
- **Strong credentials are required.** The deploy fails while `MINIO_ROOT_USER` or
  `MINIO_ROOT_PASSWORD` is empty, so the stack never falls back to a default password.
- **Hardened containers.** Both services run as non-root users (uid 1000 and 1009). The
  root filesystem is read-only, all Linux capabilities are dropped, `no-new-privileges`
  is set, and `/tmp` is a `noexec` tmpfs.
- **Supply chain.** The MinIO image and the rclone base image are pinned by digest.
  supercronic is installed from Alpine's signed package repository.
- **Secrets.** Secrets exist only in Dokploy's environment. `.env` is git-ignored, and
  rclone never writes a config file (remotes are built in memory from env vars).
  Encryption passwords are passed to rclone through stdin, never as command arguments.
- **Backups.**
  - Use a bucket-scoped R2 token and private ACLs.
  - Optional client-side encryption (rclone crypt) encrypts data before it leaves the
    server.
  - Objects that are deleted or overwritten in MinIO are kept in `archive/` for
    `BACKUP_RETENTION_DAYS` days. An accidental or malicious deletion therefore doesn't
    wipe the backup.
- **Log rotation.** Each container keeps 3 × 10 MB of logs, so logs can't fill the disk.

Recommended extras:

1. Enable **Isolated Deployment** for this compose service in Dokploy. MinIO then sits on
   its own network instead of the shared `dokploy-network`.
2. Give each application its own MinIO user or access key with a narrow policy. Never
   put the root credentials in applications.
3. Give the backup job its own read-only user. See
   [Least-privilege backup user](#least-privilege-backup-user).
4. Protect the console. You can:
   - Disable it with `MINIO_BROWSER=off` and manage MinIO with `mc`.
   - Put it behind Cloudflare Access or an IP allow-list.
   - Skip adding a console domain.
5. Set `BACKUP_ENCRYPTION_PASSWORD` and `BACKUP_ENCRYPTION_SALT`.

## Deploy on Dokploy

**Prerequisites:**

- A Dokploy server.
- Two DNS `A`/`AAAA` records pointing to it, for example `s3.example.com` (API) and
  `console.example.com` (console). If you use Cloudflare DNS, keep the API record
  **DNS only** (grey cloud). The Cloudflare proxy limits request bodies to 100 MB and
  would break large uploads.

**Steps:**

1. Push this repository to your Git provider (GitHub, GitLab, Gitea, …).
2. In Dokploy, open a project and choose **Create Service → Compose**. Select type
   **Docker Compose**.
3. Under **General → Provider**, pick the repository and branch. Set **Compose Path**
   to `./docker-compose.yml`. Save.
   > Deploy from Git, not by pasting "Raw" YAML. The `backup` service is built from
   > [backup/](backup/), so the build context must exist on the server.
4. On the **Environment** tab, paste the contents of [.env.example](.env.example). Fill
   in at least these, then save:
   - `MINIO_ROOT_USER` and `MINIO_ROOT_PASSWORD`. Generate them with
     `openssl rand -hex 32`.
   - `MINIO_BROWSER_REDIRECT_URL`, set to the **console** domain (the one on port 9001).
5. On the **Domains** tab, add two domains, one per port. For both, turn **HTTPS** on
   and choose **Let's Encrypt** as the certificate provider:

   | Service | Host | Container port | Serves |
   | --- | --- | --- | --- |
   | `minio` | `s3.example.com` | `9000` | S3 API |
   | `minio` | `console.example.com` | `9001` | Web console |

   No DNS yet? [sslip.io](https://sslip.io) names work too, for example
   `s3-203-0-113-10.sslip.io` and `console-203-0-113-10.sslip.io` (use your server's IP).

6. Optional but recommended: enable **Isolated Deployment** in the compose service
   settings.
7. Click **Deploy**. Then open `https://console.example.com` and sign in with the root
   credentials.

### Connecting clients

| Setting | Value |
| --- | --- |
| Endpoint | `https://s3.example.com` |
| Region | `us-east-1` |
| Addressing | **Path-style** (`forcePathStyle: true`, `s3ForcePathStyle`, `addressing_style = path`) |

```sh
aws --endpoint-url https://s3.example.com s3 ls
```

### Run locally

```sh
cp .env.example .env        # fill in the required values
docker compose up -d --build
```

No ports are published. For local access, create a `docker-compose.override.yml`
(git-ignored) with this content:

```yaml
services:
  minio:
    ports: ["127.0.0.1:9000:9000", "127.0.0.1:9001:9001"]
```

## Backups to Cloudflare R2

The `backup` service runs [rclone](https://rclone.org) on a cron schedule
([supercronic](https://github.com/aptible/supercronic)). It reads every object through
the S3 API, so each copy is consistent per object and MinIO never has to stop. Each run
is incremental: only new or changed objects are uploaded.

### 1. Prepare R2

1. In the Cloudflare dashboard, go to **R2** and create a bucket, for example
   `my-minio-backups`. The backup job never creates buckets.
2. Go to **R2 → Manage API tokens → Create API token**. Choose the permission
   **Object Read & Write** and restrict it to that bucket. Copy the **Access Key ID**
   and **Secret Access Key**.
3. Note your **Account ID**, shown on the R2 overview page.

### 2. Configure

Set these variables on Dokploy's Environment tab, then **Deploy** again:

```dotenv
BACKUP_ENABLED=true
BACKUP_SCHEDULE="0 3 * * *"     # daily at 03:00 in TZ
TZ=Asia/Dhaka
R2_ACCOUNT_ID=<account id>
R2_ACCESS_KEY_ID=<token access key id>
R2_SECRET_ACCESS_KEY=<token secret>
R2_BUCKET=my-minio-backups
R2_PREFIX=minio                  # folder inside the bucket
BACKUP_ENCRYPTION_PASSWORD=<openssl rand -hex 32>
BACKUP_ENCRYPTION_SALT=<openssl rand -hex 32>
```

`BACKUP_SCHEDULE` is a standard 5-field cron expression. Some examples:

| Expression | Runs |
| --- | --- |
| `"0 3 * * *"` | Daily at 03:00 |
| `"0 */6 * * *"` | Every 6 hours |
| `"30 2 * * 0"` | Sundays at 02:30 |
| `"@hourly"` | Every hour |

If a run is still going when the next one is due, the next run is skipped.

For every setting, see [Environment variables](#environment-variables).

### 3. Verify

When it starts, the backup container validates its settings and tests access to MinIO
and R2. Check its logs in Dokploy:

```
[minio-backup] Backups enabled: schedule '0 3 * * *' (TZ=Asia/Dhaka), mode=sync, retention=30d, target=r2:my-minio-backups/minio (encrypted)
[minio-backup] OK: list MinIO buckets
[minio-backup] OK: list R2 bucket 'my-minio-backups' (it must already exist)
[minio-backup] OK: write to r2:my-minio-backups/minio (encrypted)
```

You can also run commands on the server over SSH. The container is named
`<dokploy-app-name>-backup-1`; find it with `docker ps | grep backup`.

```sh
docker exec <container> minio-backup check   # connectivity test
docker exec <container> minio-backup run     # back up right now
```

The container reports **unhealthy** in Docker/Dokploy while the most recent run has
failed.

### Layout in R2

```
<R2_BUCKET>/<R2_PREFIX>/
├── current/<bucket>/...                        latest copy of every object
└── archive/2026-09-26T030000Z/<bucket>/...     versions replaced or deleted by that run
```

`BACKUP_MODE` controls what happens when you delete something in MinIO:

- **`sync`** (default): `current/` mirrors MinIO exactly. Objects deleted in MinIO move
  to `archive/<run>/`.
- **`copy`**: nothing is ever removed from `current/`.

In both modes, the previous version of an overwritten object moves to `archive/<run>/`.
Archive folders older than `BACKUP_RETENTION_DAYS` are deleted after each successful
run. Set it to `0` to keep them forever.

With encryption on, R2 stores only encrypted object names and contents. The tree above
is what you see through `minio-backup rclone`.

### What is and isn't backed up

**Backed up:** the objects in every bucket, or only the buckets listed in
`BACKUP_BUCKETS`. User-defined object metadata is not copied by default; add
`--metadata` to `BACKUP_RCLONE_FLAGS` to include it.

**Not backed up:**

- MinIO users, policies and access keys.
- Bucket settings: policies, versioning, lifecycle, notifications and object lock.
- Old object versions in versioned buckets. Only the latest version is copied.

Export the first two after changes, for example with `mc admin cluster iam export` and
`mc admin cluster bucket export`. Or keep a record of how you created them.

### Encryption

When `BACKUP_ENCRYPTION_PASSWORD` is set, backups go through an
[rclone crypt](https://rclone.org/crypt/) layer:

- File contents are encrypted with XSalsa20-Poly1305.
- File and folder names are encrypted with AES-256-EME.
- Keys are derived with scrypt from the password and the salt.

> **Save the password and salt in a password manager.** Without them the backups cannot
> be decrypted, by you or by anyone else. Don't change them once backups exist. To
> switch encryption on or off, or to rotate the keys, use a new `R2_PREFIX`.

### Least-privilege backup user

By default the backup job uses the root credentials. To give it read-only access
instead:

1. Create a policy named `backup-readonly`, either in the console under Policies or with
   `mc admin policy create`:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": ["s3:ListAllMyBuckets", "s3:GetBucketLocation", "s3:ListBucket", "s3:GetObject"],
         "Resource": ["arn:aws:s3:::*"]
       }
     ]
   }
   ```

   MinIO's built-in `readonly` policy is not enough, because it cannot list objects.

2. Create a user, for example `backup`, attach the policy, and set
   `BACKUP_MINIO_ACCESS_KEY` and `BACKUP_MINIO_SECRET_KEY`.
3. Redeploy.

Restoring needs write access. For a restore, pass the root credentials explicitly:
`docker exec -e MINIO_ACCESS_KEY=... -e MINIO_SECRET_KEY=... <container> minio-backup restore ...`.

### Monitoring

The backup job can call a URL when a run starts, succeeds or fails. It works with any
service that accepts an HTTP GET, such as [healthchecks.io](https://healthchecks.io)
(which also alerts when a run never happens) or an Uptime Kuma push monitor:

```dotenv
BACKUP_PING_START_URL=https://hc-ping.com/<uuid>/start
BACKUP_PING_SUCCESS_URL=https://hc-ping.com/<uuid>
BACKUP_PING_FAILURE_URL=https://hc-ping.com/<uuid>/fail
```

### Restore

All restores use `rclone copy`, so they never delete anything in MinIO.

```sh
# Browse the backup (decrypted view)
docker exec <container> minio-backup rclone lsd backup:current
docker exec <container> minio-backup rclone ls  backup:current/photos

# Restore a whole bucket (created if missing)…
docker exec <container> minio-backup restore photos
# …or restore it into a different bucket to compare first
docker exec <container> minio-backup restore photos photos-restored

# Recover an object that a run replaced or deleted
docker exec <container> minio-backup rclone lsd backup:archive
docker exec <container> minio-backup rclone copy \
  backup:archive/2026-09-26T030000Z/photos/report.pdf minio:photos/
```

`minio-backup rclone …` accepts any rclone command. It comes with three remotes already
configured:

- `minio:` is this stack's MinIO.
- `r2:` is the raw R2 account.
- `backup:` is `R2_BUCKET/R2_PREFIX`, decrypted when encryption is on.

**Disaster recovery (new server):**

1. Deploy this stack with the same R2 settings and the same `BACKUP_ENCRYPTION_*`
   values.
2. Run `minio-backup restore <bucket>` for each bucket.
3. Recreate users, policies and bucket settings.

## Upgrading

- **MinIO (silo):**
  1. Pick a release from [pgsty/silo releases](https://github.com/pgsty/silo/releases)
     and read its notes.
  2. Get the digest with
     `docker buildx imagetools inspect pgsty/silo:<RELEASE>-distroless`.
  3. Update the `image:` line in [docker-compose.yml](docker-compose.yml), commit, and
     redeploy.
- **rclone:** update the `FROM` tag and digest in [backup/Dockerfile](backup/Dockerfile).
- **Migrating an existing `minio/minio` deployment:** the data format is compatible.
  However, the old image ran as root, and this stack runs MinIO as uid 1000. Stop the
  stack and fix ownership once:

  ```sh
  docker run --rm -v <volume-name>:/data busybox chown -R 1000:1000 /data
  ```

## Troubleshooting

**Deploy fails with `required variable MINIO_ROOT_USER is missing a value`.**
Fill in the root credentials on the Environment tab.

**A password with `$` in it doesn't work.**
Wrap the value in single quotes, for example `MINIO_ROOT_PASSWORD='abc$def'`.
Otherwise Compose treats `$def` as a variable.

**MinIO exits with a permission or "unable to write" error on `/data`.**
The volume holds root-owned data from an older deployment. Run the `chown` command from
[Upgrading](#upgrading).

**The browser says "redirected you too many times" (307 loop).**
The domain you opened is routed to port **9000** (the S3 API; responses carry
`X-Amz-Request-Id` headers), and `MINIO_BROWSER_REDIRECT` is `on` with
`MINIO_BROWSER_REDIRECT_URL` pointing at that same domain. Route a separate domain to
port **9001** for the console, set `MINIO_BROWSER_REDIRECT_URL` to it, and keep
`MINIO_BROWSER_REDIRECT=off`.

**The console domain shows an XML `AccessDenied` page.**
That domain is routed to port 9000. Change its container port to 9001.

**Console login fails.**
Check that `MINIO_BROWSER_REDIRECT_URL` is exactly the console URL, including
`https://`. Leave `MINIO_SERVER_URL` empty.

**Uploads that take longer than about 60 s fail.**
Traefik v3 has a 60 s default read timeout. Add this under `entryPoints.websecure` in
`/etc/dokploy/traefik/traefik.yml` (the Traefik config in Dokploy), then restart
Traefik:

```yaml
transport:
  respondingTimeouts:
    readTimeout: 600s
```

**Uploads larger than 100 MB fail.**
The domain is proxied by Cloudflare. Switch the API record to DNS only.

**SDK errors like `bucket.s3.example.com` not found.**
Enable path-style addressing in the client.

**Backup check fails with `directory not found` on the R2 bucket.**
The bucket doesn't exist, or `R2_ACCOUNT_ID` or `R2_ENDPOINT` is wrong.

**Backup check fails with `SignatureDoesNotMatch` or `AccessDenied`.**
The R2 keys are wrong, or the token isn't allowed to read and write that bucket.

**The backup container keeps restarting.**
A setting is invalid. The last log line names it.

## Environment variables

| Variable | Default | Description |
| --- | --- | --- |
| `MINIO_ROOT_USER` | *required* | Root user name |
| `MINIO_ROOT_PASSWORD` | *required* | Root password (8+ chars; use 32+ random) |
| `MINIO_BROWSER_REDIRECT_URL` | – | Public console URL (the port-9001 domain) |
| `MINIO_BROWSER_REDIRECT` | `off` | `on` redirects browsers from the API domain to the console |
| `MINIO_SERVER_URL` | – | Public S3 API URL (optional) |
| `MINIO_BROWSER` | `on` | `off` disables the web console |
| `BACKUP_ENABLED` | `false` | Turn scheduled backups on |
| `BACKUP_SCHEDULE` | `0 3 * * *` | Cron expression, evaluated in `TZ` |
| `TZ` | `UTC` | Time zone for the schedule |
| `BACKUP_RUN_ON_STARTUP` | `false` | Also back up whenever the container starts |
| `BACKUP_MODE` | `sync` | `sync` mirrors deletions into `archive/`; `copy` never removes |
| `BACKUP_BUCKETS` | all | Comma-separated bucket names |
| `BACKUP_RETENTION_DAYS` | `30` | Days to keep `archive/` runs; `0` keeps them forever |
| `R2_ACCOUNT_ID` | – | Cloudflare account ID (builds the endpoint URL) |
| `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` | – | R2 API token keys |
| `R2_BUCKET` | – | Existing R2 bucket |
| `R2_PREFIX` | `minio` | Folder inside the bucket |
| `R2_ENDPOINT` | derived | Override, e.g. `https://<id>.eu.r2.cloudflarestorage.com` |
| `BACKUP_ENCRYPTION_PASSWORD` / `_SALT` | – | Turns on client-side encryption |
| `BACKUP_MINIO_ACCESS_KEY` / `_SECRET_KEY` | root | Credentials the backup job uses to read MinIO |
| `BACKUP_PING_START_URL` / `_SUCCESS_URL` / `_FAILURE_URL` | – | Monitoring URLs (HTTP GET) |
| `BACKUP_RCLONE_FLAGS` | – | Extra rclone flags, e.g. `--transfers 8 --bwlimit 20M --fast-list` |
