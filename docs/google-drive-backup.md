# Back up MinIO to Google Drive (personal account)

This guide sets the `backup` service to copy your MinIO buckets into a folder in your
personal Google Drive on a schedule, instead of Cloudflare R2. It takes about 15
minutes.

How it works:

- rclone connects to Drive with your own Google OAuth client, using the **`drive.file`**
  scope. That token can only see and change files that rclone itself created. It
  cannot read anything else in your Drive.
- The token lives only in Dokploy's environment. rclone never writes a config file.
- Leave encryption on. Otherwise Google stores your data in readable form.

You will do three things:

1. Create a Google OAuth client, once, in Google Cloud Console.
2. Get a token by signing in once from a machine with a web browser.
3. Paste the values into Dokploy and deploy.

## Before you start

- Your Google account has enough free space. The free 15 GB is shared with Gmail and
  Photos. The backup needs roughly the size of your MinIO data, plus whatever sits in
  `archive/` during the retention period.
- The MinIO stack is already running on Dokploy (see the [README](../README.md)).
- This repository version, which includes Google Drive support, is the one Dokploy
  deploys.

## Step 1: Create your own Google OAuth client

rclone's shared client ID is being retired during 2026 and is heavily rate-limited, so
you need your own. It's free.

1. Open <https://console.cloud.google.com/> and sign in with the Google account whose
   Drive will hold the backups.
2. Create a project:
   1. Click the project picker at the top, then **New project**.
   2. Name it, for example `minio-backup`, and click **Create**.
   3. Make sure the new project is selected.
3. Enable the Drive API:
   1. Go to **APIs & Services → Library**.
   2. Search for **Google Drive API**, open it, and click **Enable**.
4. Configure the consent screen:
   1. Go to **APIs & Services → OAuth consent screen**. This opens the "Google Auth
      Platform" section. Click **Get started**.
   2. **App name:** `MinIO Backup`. **User support email:** your Gmail address.
   3. **Audience:** **External**.
   4. **Contact information:** your email. Accept the policy and click **Create**.
5. Add the scope:
   1. Go to **Data Access → Add or remove scopes**.
   2. Filter for `drive.file` and tick `.../auth/drive.file`. Google classes it as
      non-sensitive, so it needs no review.
   3. Click **Update**, then **Save**.
6. Publish the app. **Do not skip this step.**
   1. Go to **Audience** and click **Publish app**, then **Confirm**.
   2. The status should now say **In production**.

   > While the app is in **Testing**, Google expires the token after **7 days**, and
   > every backup after that fails with `invalid_grant`. You don't need Google's
   > verification for personal use.
7. Create the client:
   1. Go to **Clients → Create client**.
   2. **Application type:** **Desktop app**. **Name:** `rclone`.
   3. Click **Create**.
   4. Copy the **Client ID** (`…apps.googleusercontent.com`) and the **Client secret**
      (`GOCSPX-…`), or click **Download JSON**. Google may not show the secret again.

## Step 2: Get the token (one-time sign-in)

Google has to show you a sign-in page in a browser, and your server has none. So you
run a one-off `rclone authorize` somewhere you do have a browser. Pick **one** option.

### Option A: rclone on your Windows PC (easiest)

Open PowerShell and run:

```powershell
winget install Rclone.Rclone
# Close and reopen PowerShell so `rclone` is on PATH, then:
rclone authorize "drive" "YOUR_CLIENT_ID" "YOUR_CLIENT_SECRET" --drive-scope drive.file
```

On macOS or Linux, install rclone from <https://rclone.org/install/> and run the same
`rclone authorize …` command.

### Option B: on the server, through an SSH tunnel (nothing to install locally)

```sh
# On your PC: open an SSH session that forwards port 53682
ssh -L 53682:127.0.0.1:53682 user@your-server

# Inside that SSH session:
docker run --rm -it --network host rclone/rclone:1.75.1 \
  authorize "drive" "YOUR_CLIENT_ID" "YOUR_CLIENT_SECRET" \
  --drive-scope drive.file --auth-no-open-browser
```

Open the `http://127.0.0.1:53682/auth?state=…` link it prints in your PC's browser.

### Then, for either option

1. Choose your Google account and click **Continue** or **Allow**.
   - If Google says "Google hasn't verified this app", click **Advanced → Go to MinIO
     Backup**. It's your own app.
2. The browser shows **Success**. The terminal prints something like this:

   ```
   Paste the following into your remote machine --->
   {"access_token":"ya29.a0…","token_type":"Bearer","refresh_token":"1//0g…","expiry":"2026-09-26T19:08:04+06:00","expires_in":3599}
   <---End paste
   ```

3. Copy the whole `{…}` line. That is your `GDRIVE_TOKEN`.

   Treat it like a password: anyone who has it can write to this app's files in your
   Drive.

## Step 3: Configure Dokploy

1. In Dokploy, open the compose service → **Environment**. Set the following values and
   **Save**:

   ```dotenv
   BACKUP_ENABLED=true
   BACKUP_TARGET=gdrive
   BACKUP_SCHEDULE="0 3 * * *"        # daily at 03:00
   TZ=Asia/Dhaka
   BACKUP_RETENTION_DAYS=30

   GDRIVE_CLIENT_ID=1234567890-abc123.apps.googleusercontent.com
   GDRIVE_CLIENT_SECRET=GOCSPX-xxxxxxxxxxxxxxxxxxxx
   GDRIVE_TOKEN='{"access_token":"ya29.a0…","token_type":"Bearer","refresh_token":"1//0g…","expiry":"2026-09-26T19:08:04+06:00","expires_in":3599}'
   GDRIVE_FOLDER=minio-backups

   BACKUP_ENCRYPTION_PASSWORD=<output of: openssl rand -hex 32>
   BACKUP_ENCRYPTION_SALT=<output of: openssl rand -hex 32>
   ```

   Pay attention to these points:
   - **`GDRIVE_TOKEN` must be on one line, inside single quotes `'…'`.** Without the
     quotes, Compose may mangle the JSON.
   - **Don't create the `GDRIVE_FOLDER` folder in Drive yourself.** With the `drive.file`
     scope, rclone can't see folders it didn't create. It would make a second folder
     with the same name. rclone creates the folder on the first run.
   - **Save the encryption password and salt in a password manager.** Without them the
     backups can't be restored.
   - You can leave the `R2_*` variables empty.
2. Click **Deploy**.

## Step 4: Verify

1. Open the **backup** container's logs in Dokploy. You should see:

   ```
   [minio-backup] Backups enabled: schedule '0 3 * * *' (TZ=Asia/Dhaka), mode=sync, retention=30d, target=gdrive:minio-backups (encrypted)
   [minio-backup] OK: list MinIO buckets
   [minio-backup] OK: sign in to Google Drive
   [minio-backup] OK: write to gdrive:minio-backups (encrypted)
   ```

2. Run a first backup now instead of waiting for the schedule. Over SSH on the server
   (find the container name with `docker ps | grep backup`):

   ```sh
   docker exec <app-name>-backup-1 minio-backup run
   ```

3. Open <https://drive.google.com>. A `minio-backups` folder now contains `current/`.
   With encryption on, the names inside look random; that's expected.

To browse the backup in its decrypted form:

```sh
docker exec <app-name>-backup-1 minio-backup rclone lsd backup:current
docker exec <app-name>-backup-1 minio-backup rclone about gdrive:     # Drive quota
```

## Restore

Restores work the same way as with R2, and never delete anything in MinIO:

```sh
docker exec <app-name>-backup-1 minio-backup restore photos                  # into bucket "photos"
docker exec <app-name>-backup-1 minio-backup restore photos photos-restored  # into a new bucket
```

To restore on a new server, deploy the stack with the **same** `GDRIVE_*` and
`BACKUP_ENCRYPTION_*` values, then run `minio-backup restore <bucket>` for each bucket.

If you ever need the data without this stack, create an rclone `crypt` remote on your
PC. Point it at `gdrive:minio-backups`, with the same password and salt. Use a
`drive` remote with the same client ID, authorized with the same `drive.file` scope.

## Limits and good practice

- **Quota.** The Drive quota is shared with Gmail and Photos. When it's full, runs fail
  with `storageQuotaExceeded`. Lower `BACKUP_RETENTION_DAYS` or buy more storage.
  Expired archives are deleted permanently, not moved to the Drive trash, so they don't
  keep using quota.
- **Upload cap.** Google allows about 750 GB of uploads per account per day. A very
  large first backup takes several days; each later run only uploads changes.
- **Many small files are slow.** The Drive API is rate-limited. If the logs show
  `rate limit exceeded`, add `BACKUP_RCLONE_FLAGS=--tpslimit 8`.
- **Don't rename or move** the backup folder in the Drive UI. rclone finds it by name.
- **Token lifetime.** The token keeps working while the app is **In production**. It
  stops working if:
  - You remove the app's access at <https://myaccount.google.com/permissions>.
  - You delete the OAuth client.
  - The token goes unused for six months.

  If any of these happens, repeat Step 2 and update `GDRIVE_TOKEN`.

## Troubleshooting

| Log message | Cause and fix |
| --- | --- |
| `GDRIVE_TOKEN must be the JSON printed by 'rclone authorize'` | The value is empty, cut off or missing its quotes. Paste the full `{…}` line inside single quotes. |
| `invalid_client` | Wrong client ID or secret, or the client isn't a **Desktop app**. Create a new Desktop client and authorize again. |
| `invalid_grant` or `token expired or revoked` | The app is still in **Testing** (7-day tokens), or access was revoked. Publish the app (Step 1.6), repeat Step 2, and update `GDRIVE_TOKEN`. |
| `Error 400: redirect_uri_mismatch` (in the browser) | The client type isn't **Desktop app**. |
| `Access blocked: … has not completed the Google verification process` | The app is in Testing and your account isn't a test user. Publish the app. |
| `storageQuotaExceeded` | The Drive is full. |
| `userRateLimitExceeded` or `rateLimitExceeded` | Add `--tpslimit 8` to `BACKUP_RCLONE_FLAGS`. |
| Two `minio-backups` folders in Drive | One was created by hand. Delete the hand-made, empty one. |
