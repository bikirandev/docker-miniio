# Backup sidecar: official rclone image + supercronic (a cron built for containers).
# Base pinned by digest; bump both tag and digest together when upgrading rclone.
FROM rclone/rclone:1.75.1@sha256:45401ad7410db1d67ffdb58e19059ad20b0d8e0285a60e38bbec55cc1019c7a5

# Signed Alpine package (community repo of the base image's Alpine release).
RUN apk add --no-cache supercronic

COPY --chmod=0755 minio-backup.sh /usr/local/bin/minio-backup

# Runs as the unprivileged "rclone" user (uid/gid 1009) that the base image creates.
# The root filesystem is mounted read-only at runtime, so all scratch state lives in /tmp.
ENV HOME=/tmp
WORKDIR /tmp
USER 1009:1009

ENTRYPOINT ["/usr/local/bin/minio-backup"]
CMD ["daemon"]
