FROM alpine:3.24

RUN apk add --no-cache age ca-certificates rclone sqlite tar tini tzdata zstd

COPY --chmod=755 backup.sh /usr/local/bin/backup

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["backup"]
