ARG BUILD_FROM=ghcr.io/home-assistant/base:3.24
FROM $BUILD_FROM

RUN apk add --no-cache git openssh-client rsync

COPY run.sh /run.sh
RUN chmod +x /run.sh

CMD ["/run.sh"]
