#!/bin/sh
# minio-backup - scheduled MinIO backups to Cloudflare R2 or Google Drive (rclone + supercronic).
#
# Usage: minio-backup <command>
#   daemon                    Validate config, then back up on BACKUP_SCHEDULE (default).
#   run                       Run one backup now.
#   check                     Test access to MinIO and the backup target.
#   restore <bucket> [target] Copy current/<bucket> from the backup into MinIO (never deletes).
#   rclone <args...>          Run rclone with the minio:, target and backup: remotes configured.
#   healthcheck               Exit non-zero if the last backup failed (used by Docker).
#
# Layout in the target folder (encrypted when BACKUP_ENCRYPTION_PASSWORD is set):
#   current/<bucket>/...              latest copy of every object
#   archive/<timestamp>/<bucket>/...  objects overwritten or deleted by the run at <timestamp>
set -euf

STATE_DIR=/tmp/minio-backup
STATUS_FILE="$STATE_DIR/last-status"
LOCK_DIR="$STATE_DIR/lock"
CRONTAB="$STATE_DIR/crontab"
STATS_FLAGS="--stats 1m --stats-one-line --stats-log-level NOTICE"

log() { printf '%s [minio-backup] %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$*"; }
die() {
	log "ERROR: $*" >&2
	exit 1
}

usage() { sed -n '2,15s/^# \{0,1\}//p' "$0"; }

is_true() {
	case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
	1 | true | yes | on) return 0 ;;
	*) return 1 ;;
	esac
}

valid_bucket() {
	case "$1" in
	'' | *[!a-z0-9.-]*) return 1 ;;
	*) return 0 ;;
	esac
}

trim_slashes() {
	p=${1#/}
	printf '%s' "${p%/}"
}

# Sets TARGET_PATH (rclone path of the backup root) and TARGET_PROBE_* for `check`.
configure_r2() {
	[ -n "${R2_ACCESS_KEY_ID:-}" ] || die "R2_ACCESS_KEY_ID is not set"
	[ -n "${R2_SECRET_ACCESS_KEY:-}" ] || die "R2_SECRET_ACCESS_KEY is not set"
	[ -n "${R2_BUCKET:-}" ] || die "R2_BUCKET is not set"
	if [ -z "${R2_ENDPOINT:-}" ]; then
		[ -n "${R2_ACCOUNT_ID:-}" ] || die "R2_ACCOUNT_ID (or R2_ENDPOINT) is not set"
		R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
	fi

	export RCLONE_CONFIG_R2_TYPE=s3
	export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
	export RCLONE_CONFIG_R2_ENDPOINT="$R2_ENDPOINT"
	export RCLONE_CONFIG_R2_REGION=auto
	export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
	export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
	export RCLONE_CONFIG_R2_ACL=private
	# Bucket-scoped R2 tokens cannot create buckets, so never try: the bucket must exist.
	export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true

	prefix=$(trim_slashes "${R2_PREFIX:-}")
	TARGET_PATH="r2:$R2_BUCKET${prefix:+/$prefix}"
	TARGET_PROBE_LABEL="list R2 bucket '$R2_BUCKET' (it must already exist)"
	TARGET_PROBE_ARGS="lsd r2:$R2_BUCKET"
}

configure_gdrive() {
	[ -n "${GDRIVE_CLIENT_ID:-}" ] || die "GDRIVE_CLIENT_ID is not set"
	[ -n "${GDRIVE_CLIENT_SECRET:-}" ] || die "GDRIVE_CLIENT_SECRET is not set"
	case "${GDRIVE_TOKEN:-}" in
	'{'*'refresh_token'*'}') ;;
	*) die "GDRIVE_TOKEN must be the JSON printed by 'rclone authorize' (wrap it in single quotes)" ;;
	esac
	folder=$(trim_slashes "${GDRIVE_FOLDER:-minio-backups}")
	[ -n "$folder" ] || die "GDRIVE_FOLDER must name a folder, not the root of My Drive"

	export RCLONE_CONFIG_GDRIVE_TYPE=drive
	export RCLONE_CONFIG_GDRIVE_CLIENT_ID="$GDRIVE_CLIENT_ID"
	export RCLONE_CONFIG_GDRIVE_CLIENT_SECRET="$GDRIVE_CLIENT_SECRET"
	export RCLONE_CONFIG_GDRIVE_TOKEN="$GDRIVE_TOKEN"
	# drive.file: rclone only ever sees files it created itself, nothing else in the Drive.
	export RCLONE_CONFIG_GDRIVE_SCOPE=drive.file
	# Expired archives are deleted for good instead of filling the Drive trash (and quota).
	export RCLONE_CONFIG_GDRIVE_USE_TRASH=false

	TARGET_PATH="gdrive:$folder"
	TARGET_PROBE_LABEL="sign in to Google Drive"
	TARGET_PROBE_ARGS="about gdrive:"
}

# Define rclone remotes purely from the environment; no config file is ever written.
configure() {
	[ -n "${MINIO_ACCESS_KEY:-}" ] || die "MINIO_ACCESS_KEY is not set"
	[ -n "${MINIO_SECRET_KEY:-}" ] || die "MINIO_SECRET_KEY is not set"

	BACKUP_MODE=${BACKUP_MODE:-sync}
	case "$BACKUP_MODE" in
	sync | copy) ;;
	*) die "BACKUP_MODE must be 'sync' or 'copy' (got '$BACKUP_MODE')" ;;
	esac
	BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-30}
	case "$BACKUP_RETENTION_DAYS" in
	'' | *[!0-9]*) die "BACKUP_RETENTION_DAYS must be a whole number (got '$BACKUP_RETENTION_DAYS')" ;;
	esac

	# /dev/null = keep rclone's config in memory only.
	export RCLONE_CONFIG=/dev/null

	export RCLONE_CONFIG_MINIO_TYPE=s3
	export RCLONE_CONFIG_MINIO_PROVIDER=Minio
	export RCLONE_CONFIG_MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://minio:9000}"
	export RCLONE_CONFIG_MINIO_ACCESS_KEY_ID="$MINIO_ACCESS_KEY"
	export RCLONE_CONFIG_MINIO_SECRET_ACCESS_KEY="$MINIO_SECRET_KEY"

	BACKUP_TARGET=${BACKUP_TARGET:-r2}
	case "$BACKUP_TARGET" in
	r2) configure_r2 ;;
	gdrive) configure_gdrive ;;
	*) die "BACKUP_TARGET must be 'r2' or 'gdrive' (got '$BACKUP_TARGET')" ;;
	esac

	# "backup:" is the root holding current/ and archive/ - the target directly, or behind rclone crypt.
	export RCLONE_CONFIG_BACKUP_TYPE=alias
	if [ -n "${BACKUP_ENCRYPTION_PASSWORD:-}" ]; then
		export RCLONE_CONFIG_CRYPT_TYPE=crypt
		export RCLONE_CONFIG_CRYPT_REMOTE="$TARGET_PATH"
		export RCLONE_CONFIG_CRYPT_FILENAME_ENCRYPTION=standard
		export RCLONE_CONFIG_CRYPT_DIRECTORY_NAME_ENCRYPTION=true
		# Read from stdin so the secrets never appear in a process argument list.
		RCLONE_CONFIG_CRYPT_PASSWORD=$(printf '%s' "$BACKUP_ENCRYPTION_PASSWORD" | rclone obscure -)
		export RCLONE_CONFIG_CRYPT_PASSWORD
		if [ -n "${BACKUP_ENCRYPTION_SALT:-}" ]; then
			RCLONE_CONFIG_CRYPT_PASSWORD2=$(printf '%s' "$BACKUP_ENCRYPTION_SALT" | rclone obscure -)
			export RCLONE_CONFIG_CRYPT_PASSWORD2
		fi
		export RCLONE_CONFIG_BACKUP_REMOTE="crypt:"
		DEST_DESC="$TARGET_PATH (encrypted)"
	else
		export RCLONE_CONFIG_BACKUP_REMOTE="$TARGET_PATH"
		DEST_DESC="$TARGET_PATH"
	fi
}

ping_url() {
	[ -n "${1:-}" ] || return 0
	wget -q -T 15 -O /dev/null "$1" 2>/dev/null || log "WARN: could not reach notification URL"
}

acquire_lock() {
	mkdir -p "$STATE_DIR"
	if mkdir "$LOCK_DIR" 2>/dev/null; then
		echo $$ >"$LOCK_DIR/pid"
		return 0
	fi
	pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
	if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
		return 1
	fi
	log "Removing stale lock left by pid ${pid:-unknown}"
	rm -rf "$LOCK_DIR"
	mkdir "$LOCK_DIR" && echo $$ >"$LOCK_DIR/pid"
}

# $1 = bucket ('' = every bucket), $2 = run timestamp
sync_target() {
	if [ -n "$1" ]; then
		src="minio:$1" dst="backup:current/$1" bdir="backup:archive/$2/$1"
	else
		src="minio:" dst="backup:current" bdir="backup:archive/$2"
	fi
	log "rclone $BACKUP_MODE $src -> $dst"
	# Word splitting is intended: the flag strings expand to separate arguments.
	# shellcheck disable=SC2086
	rclone "$BACKUP_MODE" "$src" "$dst" --backup-dir "$bdir" $STATS_FLAGS ${BACKUP_RCLONE_FLAGS:-}
}

# Delete archive/<timestamp> folders older than BACKUP_RETENTION_DAYS.
prune_archive() {
	[ "$BACKUP_RETENTION_DAYS" -gt 0 ] || return 0
	cutoff=$(date -u -d "@$(($(date +%s) - BACKUP_RETENTION_DAYS * 86400))" +%Y-%m-%dT%H%M%SZ)
	# A missing archive/ folder (nothing archived yet) is not an error.
	dirs=$(rclone lsf --dirs-only backup:archive 2>/dev/null) || return 0
	rc=0
	for d in $dirs; do
		d=${d%/}
		case "$d" in
		[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;;
		*) continue ;;
		esac
		if awk -v a="$d" -v b="$cutoff" 'BEGIN { exit !(a < b) }'; then
			log "Pruning archive/$d (older than $BACKUP_RETENTION_DAYS days)"
			rclone purge "backup:archive/$d" || rc=1
		fi
	done
	return "$rc"
}

run_backup() {
	configure
	if ! acquire_lock; then
		log "Previous backup is still running; skipping this run."
		return 0
	fi
	trap 'rm -rf "$LOCK_DIR"' EXIT
	trap 'exit 143' INT TERM

	started=$(date +%s)
	ts=$(date -u +%Y-%m-%dT%H%M%SZ)
	log "Backup $ts started: MinIO -> $DEST_DESC (mode=$BACKUP_MODE, buckets=${BACKUP_BUCKETS:-all})"
	ping_url "${BACKUP_PING_START_URL:-}"

	failed=0
	if [ -n "${BACKUP_BUCKETS:-}" ]; then
		for bucket in $(printf '%s' "$BACKUP_BUCKETS" | tr ',' ' '); do
			if ! valid_bucket "$bucket"; then
				log "ERROR: invalid bucket name '$bucket' in BACKUP_BUCKETS"
				failed=1
				continue
			fi
			sync_target "$bucket" "$ts" || failed=1
		done
	else
		sync_target "" "$ts" || failed=1
	fi
	# Only expire old history after a fully successful run.
	if [ "$failed" -eq 0 ]; then
		prune_archive || failed=1
	fi

	elapsed=$(($(date +%s) - started))
	if [ "$failed" -eq 0 ]; then
		echo ok >"$STATUS_FILE"
		log "Backup $ts finished successfully in ${elapsed}s"
		ping_url "${BACKUP_PING_SUCCESS_URL:-}"
		return 0
	fi
	echo failed >"$STATUS_FILE"
	log "ERROR: backup $ts FAILED after ${elapsed}s - see rclone output above"
	ping_url "${BACKUP_PING_FAILURE_URL:-}"
	return 1
}

# $1 = label, rest = rclone arguments
probe() {
	label=$1
	shift
	if out=$(rclone "$@" 2>&1 >/dev/null); then
		log "OK: $label"
		return 0
	fi
	log "FAILED: $label: $(printf '%s\n' "$out" | tail -n 1)"
	return 1
}

check() {
	configure
	rc=0
	if [ -n "${BACKUP_BUCKETS:-}" ]; then
		for bucket in $(printf '%s' "$BACKUP_BUCKETS" | tr ',' ' '); do
			probe "read MinIO bucket '$bucket'" lsd "minio:$bucket" || rc=1
		done
	else
		probe "list MinIO buckets" lsd minio: || rc=1
	fi
	# shellcheck disable=SC2086
	probe "$TARGET_PROBE_LABEL" $TARGET_PROBE_ARGS || rc=1
	if printf 'ok\n' | probe "write to $DEST_DESC" rcat backup:.minio-backup-write-test; then
		rclone deletefile backup:.minio-backup-write-test >/dev/null 2>&1 || true
	else
		rc=1
	fi
	return "$rc"
}

restore() {
	[ $# -ge 1 ] || die "usage: minio-backup restore <bucket> [target-bucket]"
	configure
	from=$1
	to=${2:-$1}
	valid_bucket "$from" || die "invalid bucket name '$from'"
	valid_bucket "$to" || die "invalid bucket name '$to'"
	log "Restoring backup:current/$from -> minio:$to (copy only; nothing in MinIO is deleted)"
	# shellcheck disable=SC2086
	rclone copy "backup:current/$from" "minio:$to" $STATS_FLAGS
	log "Restore of '$from' finished"
}

daemon() {
	if ! is_true "${BACKUP_ENABLED:-false}"; then
		log "Backups are disabled (set BACKUP_ENABLED=true to enable). Idling."
		while :; do sleep 3600; done
	fi
	configure
	schedule=${BACKUP_SCHEDULE:-0 3 * * *}
	mkdir -p "$STATE_DIR"
	printf '%s /usr/local/bin/minio-backup run\n' "$schedule" >"$CRONTAB"
	supercronic -test "$CRONTAB" >/dev/null 2>&1 ||
		die "BACKUP_SCHEDULE is not a valid cron expression: '$schedule'"

	log "Backups enabled: schedule '$schedule' (TZ=${TZ:-UTC}), mode=$BACKUP_MODE, retention=${BACKUP_RETENTION_DAYS}d, target=$DEST_DESC"
	check || log "WARN: connectivity check failed - fix the settings above; scheduled runs will keep retrying."
	if is_true "${BACKUP_RUN_ON_STARTUP:-false}"; then
		/usr/local/bin/minio-backup run || true
	fi
	# Reap zombies only when we are PID 1; under `init: true` docker-init already does it.
	reap_flag=
	[ "$$" -eq 1 ] || reap_flag=-no-reap
	# shellcheck disable=SC2086
	exec supercronic -passthrough-logs $reap_flag "$CRONTAB"
}

cmd=${1:-daemon}
[ $# -eq 0 ] || shift
case "$cmd" in
daemon) daemon ;;
run) run_backup ;;
check) check ;;
restore) restore "$@" ;;
rclone)
	configure
	exec rclone "$@"
	;;
healthcheck) [ "$(cat "$STATUS_FILE" 2>/dev/null || true)" != failed ] ;;
help | -h | --help) usage ;;
*)
	usage >&2
	exit 2
	;;
esac
