# Multi-stage build for zapret2 with SOCKS5 proxy support
FROM alpine:3.19 AS builder

# Install build dependencies
RUN apk add --no-cache \
    gcc \
    g++ \
    make \
    linux-headers \
    libnetfilter_queue-dev \
    libnfnetlink-dev \
    libmnl-dev \
    zlib-dev \
    luajit-dev \
    pkgconfig \
    bsd-compat-headers \
    libcap-dev \
    libevent-dev \
    openssl-dev

# Copy source code
WORKDIR /build
COPY . .

# Build nfqws2
WORKDIR /build/nfq2
RUN make clean && make nfqws2

# Build ip2net
WORKDIR /build/ip2net
RUN make clean && make ip2net

# Build mdig if exists
WORKDIR /build/mdig
RUN if [ -f Makefile ]; then make clean && make; fi || true

# Final stage
FROM alpine:3.19

# Install runtime dependencies
RUN apk add --no-cache \
    iptables \
    ip6tables \
    ipset \
    libnetfilter_queue \
    libnfnetlink \
    libmnl \
    zlib \
    luajit \
    curl \
    bash \
    dante-server \
    iproute2 \
    ca-certificates \
    libcap

# Copy compiled binaries
COPY --from=builder /build/nfq2/nfqws2 /usr/local/bin/
COPY --from=builder /build/ip2net/ip2net /usr/local/bin/
# Использование маски * предотвращает ошибку, если mdig не скомпилировался
COPY --from=builder /build/mdig/mdig* /usr/local/bin/

# Copy lua scripts and configs
COPY lua/ /opt/zapret2/lua/
COPY ipset/ /opt/zapret2/ipset/
COPY files/ /opt/zapret2/files/
COPY common/ /opt/zapret2/common/
COPY config.default /opt/zapret2/

# Create necessary directories
RUN mkdir -p /opt/zapret2/tmp \
    /opt/zapret2/lists \
    /var/log/zapret2

# Copy entrypoint script
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Expose SOCKS5 port
EXPOSE 1080

# Set working directory
WORKDIR /opt/zapret2

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD netstat -tuln | grep -q ':1080' || exit 1

ENTRYPOINT ["/entrypoint.sh"]
