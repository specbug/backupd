FROM alpine:3.19

RUN apk add --no-cache sqlite rclone bash yq tzdata ca-certificates

COPY backup.sh /usr/local/bin/backup.sh
RUN chmod +x /usr/local/bin/backup.sh

ENTRYPOINT ["/usr/local/bin/backup.sh"]
