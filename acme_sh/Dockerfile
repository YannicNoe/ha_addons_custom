ARG BUILD_FROM=ghcr.io/hassio-addons/base:stable
FROM $BUILD_FROM

RUN apk add --no-cache curl socat bash git openssl
RUN curl https://get.acme.sh | sh

WORKDIR /root

COPY run.sh /run.sh
RUN chmod +x /run.sh

CMD ["/run.sh"]