# =============================================================================
# zapret2 — isolated Docker container with SOCKS5 proxy
#
# Архитектура:
#   - nfqws2 перехватывает трафик ВНУТРИ контейнера через network namespace
#   - iptables правила применяются только к namespace контейнера
#   - Хостовая сеть не затрагивается вообще
#   - Dante слушает SOCKS5 и запускает соединения от имени пользователя proxyuser
#   - iptables внутри контейнера шлёт трафик proxyuser через NFQUEUE → nfqws2
#
# Требования к запуску:
#   docker run --cap-add NET_ADMIN --cap-add NET_RAW \
#              --sysctl net.netfilter.nf_conntrack_max=262144 \
#              -p 1080:1080 zapret2
# =============================================================================

# --------------- Stage 1: build ---------------
FROM alpine:3.19 AS builder

RUN apk add --no-cache \
    gcc g++ make \
    linux-headers \
    libnetfilter_queue-dev \
    libnfnetlink-dev \
    libmnl-dev \
    zlib-dev \
    luajit-dev \
    pkgconfig \
    bsd-compat-headers

WORKDIR /build
COPY . .

# nfqws2
WORKDIR /build/nfq2
RUN make clean && make nfqws2

# ip2net
WORKDIR /build/ip2net
RUN make clean && make ip2net

# mdig (опционально)
WORKDIR /build/mdig
RUN if [ -f Makefile ]; then make clean && make mdig 2>/dev/null || true; fi

# --------------- Stage 2: runtime ---------------
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

# Бинари из сборки
COPY --from=builder /build/nfq2/nfqws2       /usr/local/bin/nfqws2
COPY --from=builder /build/ip2net/ip2net      /usr/local/bin/ip2net
# mdig опционален — если не собрался файл просто не скопируется
COPY --from=builder /build/mdig/mdig*         /usr/local/bin/

# Lua скрипты и конфиги
COPY lua/            /opt/zapret2/lua/
COPY ipset/          /opt/zapret2/ipset/
COPY files/          /opt/zapret2/files/
COPY common/         /opt/zapret2/common/
RUN mkdir -p /opt/zapret2/tmp /opt/zapret2/lists /var/log/zapret2

# Скрипт запуска
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 1080

WORKDIR /opt/zapret2

HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
    CMD ss -tlnp | grep -q ':1080' || exit 1

ENTRYPOINT ["/entrypoint.sh"]