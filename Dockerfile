FROM alpine:3.24

RUN apk add --no-cache age ca-certificates rclone sqlite tar tini tzdata zstd

# remotes are configured with RCLONE_CONFIG_* variables; keep rclone's config in
# memory instead of logging that no config file exists
ENV RCLONE_CONFIG=/dev/null

COPY --chmod=755 backup.sh /usr/local/bin/backup

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["backup"]
