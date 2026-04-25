FROM alpine:3.19

RUN apk add --no-cache \
    iptables \
    ipset \
    libnetfilter_queue \
    libnfnetlink \
    libmnl \
    zlib \
    luajit \
    bash \
    dante-server \
    iproute2 \
    ca-certificates \
    libcap-utils \
    procps

COPY binaries/linux-x86_64/nfqws2  /usr/local/bin/nfqws2
COPY binaries/linux-x86_64/ip2net  /usr/local/bin/ip2net
COPY binaries/linux-x86_64/mdig    /usr/local/bin/mdig
RUN chmod +x /usr/local/bin/nfqws2 /usr/local/bin/ip2net /usr/local/bin/mdig

COPY lua/    /opt/zapret2/lua/
COPY ipset/  /opt/zapret2/ipset/
COPY files/  /opt/zapret2/files/
COPY common/ /opt/zapret2/common/

RUN mkdir -p /opt/zapret2/tmp /opt/zapret2/lists /var/log/zapret2

COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 1080
WORKDIR /opt/zapret2

HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
    CMD ss -tlnp | grep -q ':1080' || exit 1

ENTRYPOINT ["/entrypoint.sh"]