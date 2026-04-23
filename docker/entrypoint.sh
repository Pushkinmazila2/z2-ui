#!/bin/bash

# Logging configuration
LOG_LEVEL=${LOG_LEVEL:-debug}  # info or debug

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Temporary files for client tracking
CLIENT_MAP="/tmp/zapret2_client_map"
LAST_CLIENT_IP="/tmp/zapret2_last_client"
touch "$CLIENT_MAP" "$LAST_CLIENT_IP"

# Logging functions
timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

log_info() {
    local client_ip="$2"
    if [ -n "$client_ip" ]; then
        echo -e "${GREEN}[$(timestamp)] [INFO]${NC} [${MAGENTA}$client_ip${NC}] $1"
    else
        echo -e "${GREEN}[$(timestamp)] [INFO]${NC} $1"
    fi
}

log_debug() {
    if [ "$LOG_LEVEL" = "debug" ]; then
        local client_ip="$2"
        if [ -n "$client_ip" ]; then
            echo -e "${CYAN}[$(timestamp)] [DEBUG]${NC} [${MAGENTA}$client_ip${NC}] $1"
        else
            echo -e "${CYAN}[$(timestamp)] [DEBUG]${NC} $1"
        fi
    fi
}

log_warn() {
    echo -e "${YELLOW}[$(timestamp)] [WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[$(timestamp)] [ERROR]${NC} $1" >&2
}

# Extract IP from dante log line
extract_client_ip() {
    echo "$1" | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -1
}

# Extract hostname from connection
extract_hostname() {
    echo "$1" | sed -nE 's/.*to ([^:]+):.*/\1/p' | head -1
}

# Process dante logs
process_dante_log() {
    local line="$1"
    local client_ip=""
    
    # New connection
    if echo "$line" | grep -q "accept.*connection from"; then
        client_ip=$(extract_client_ip "$line")
        if [ -n "$client_ip" ]; then
            echo "$client_ip" > "$LAST_CLIENT_IP"
            log_info "New SOCKS5 connection" "$client_ip"
        fi
        return
    fi
    
    # Connection to destination
    if echo "$line" | grep -q "connect.*to"; then
        local host=$(extract_hostname "$line")
        client_ip=$(cat "$LAST_CLIENT_IP" 2>/dev/null || echo "")
        
        if [ -n "$host" ] && [ -n "$client_ip" ]; then
            echo "$host $client_ip $(timestamp)" >> "$CLIENT_MAP"
            log_info "→ $host" "$client_ip"
        fi
        return
    fi
    
    # Debug mode - log everything
    if [ "$LOG_LEVEL" = "debug" ]; then
        client_ip=$(cat "$LAST_CLIENT_IP" 2>/dev/null || echo "")
        log_debug "DANTE: $line" "$client_ip"
    fi
}

# Process nfqws2 logs
process_nfqws_log() {
    local line="$1"
    local client_ip=""
    local host=""
    
    # Extract hostname from nfqws2 output
    if echo "$line" | grep -qE "(hostname|SNI|Host:)"; then
        host=$(echo "$line" | sed -nE 's/.*(hostname|SNI|Host:)[: ]*([^ ]+).*/\2/p' | head -1)
        
        if [ -n "$host" ]; then
            # Find client IP from recent connections
            client_ip=$(grep "^$host " "$CLIENT_MAP" 2>/dev/null | tail -1 | awk '{print $2}')
        fi
    fi
    
    # DPI bypass actions
    if echo "$line" | grep -qE "(desync|fake|split|disorder)"; then
        if [ "$LOG_LEVEL" = "debug" ]; then
            log_debug "DPI: $line" "$client_ip"
        elif [ -n "$host" ]; then
            log_info "DPI bypass applied: $host" "$client_ip"
        fi
        return
    fi
    
    # Packet details in debug mode
    if [ "$LOG_LEVEL" = "debug" ]; then
        if echo "$line" | grep -qE "(packet|TCP|UDP|TLS|QUIC)"; then
            log_debug "PKT: $line" "$client_ip"
        fi
    fi
    
    # Always log errors
    if echo "$line" | grep -qiE "(error|fail)"; then
        log_error "NFQWS: $line"
    fi
}

# Configuration
log_info "Starting zapret2 SOCKS5 proxy container"
log_info "Log level: $LOG_LEVEL"

SOCKS5_PORT=${SOCKS5_PORT:-1080}
NFQUEUE_NUM=${NFQUEUE_NUM:-200}
ZAPRET_CONFIG=${ZAPRET_CONFIG:-/opt/zapret2/config}

# Load config
if [ -f "$ZAPRET_CONFIG" ] && [ ! -d "$ZAPRET_CONFIG" ]; then
    log_info "Loading custom configuration from $ZAPRET_CONFIG"
    . "$ZAPRET_CONFIG"
elif [ -f "/opt/zapret2/config.default" ]; then
    log_info "Using default configuration"
    . "/opt/zapret2/config.default"
else
    log_warn "No configuration found, using environment variables only"
fi

# Create proxy user
log_debug "Creating proxy user"
id -u proxyuser &>/dev/null || adduser -D -H -s /bin/false proxyuser

# Setup iptables
log_info "Setting up iptables rules"
iptables -t mangle -F
iptables -F

# Skip dante's own traffic
iptables -t mangle -A OUTPUT -m owner --uid-owner proxyuser -j RETURN

# Send everything else to NFQUEUE
iptables -t mangle -A OUTPUT -p tcp -j NFQUEUE --queue-num $NFQUEUE_NUM --queue-bypass
iptables -t mangle -A OUTPUT -p udp -j NFQUEUE --queue-num $NFQUEUE_NUM --queue-bypass

log_debug "iptables rules configured"

# Configure dante
log_info "Configuring dante SOCKS5 server"
cat > /etc/sockd.conf <<EOF
logoutput: stderr
internal: 0.0.0.0 port = $SOCKS5_PORT
external: eth0
clientmethod: none
socksmethod: none
user.privileged: root
user.unprivileged: proxyuser

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}
EOF

# Prepare nfqws2 options
NFQWS_OPTS="--qnum=$NFQUEUE_NUM --lua-init=@/opt/zapret2/lua/zapret-lib.lua --lua-init=@/opt/zapret2/lua/zapret-antidpi.lua"

# Debug: show loaded config
log_debug "NFQWS2_ENABLE='${NFQWS2_ENABLE}'"
log_debug "NFQWS2_OPT length: ${#NFQWS2_OPT}"
log_debug "NFQWS2_OPT first 100 chars: ${NFQWS2_OPT:0:100}"

# Check if custom strategy is provided
# Use simpler condition: if NFQWS2_OPT is not empty, use it
if [ -n "$NFQWS2_OPT" ]; then
    log_info "Using custom NFQWS2_OPT from config (length: ${#NFQWS2_OPT})"
    NFQWS_OPTS="$NFQWS_OPTS $NFQWS2_OPT"
else
    log_info "Using default DPI bypass strategy"
    NFQWS_OPTS="$NFQWS_OPTS --filter-tcp=80,443 --filter-l7=http,tls --out-range=-d10"
    NFQWS_OPTS="$NFQWS_OPTS --payload=http_req --lua-desync=fake:blob=fake_default_http:tcp_md5"
    NFQWS_OPTS="$NFQWS_OPTS --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:repeats=6"
    NFQWS_OPTS="$NFQWS_OPTS --lua-desync=multidisorder:pos=midsld"
fi

# Create named pipes for log processing
mkfifo /tmp/dante.pipe /tmp/nfqws.pipe 2>/dev/null || true

# Start dante with log processing
log_info "Starting dante SOCKS5 server on port $SOCKS5_PORT"
(
    sockd -f /etc/sockd.conf -D 2>&1 | while IFS= read -r line; do
        process_dante_log "$line"
    done
) &
SOCKS_PID=$!

# Start nfqws2 with log processing
log_info "Starting nfqws2 on queue $NFQUEUE_NUM"
log_debug "nfqws2 options: $NFQWS_OPTS"
(
    /usr/local/bin/nfqws2 $NFQWS_OPTS 2>&1 | while IFS= read -r line; do
        process_nfqws_log "$line"
    done
) &
NFQWS_PID=$!

# Graceful shutdown
trap 'log_info "Shutting down..."; kill $SOCKS_PID $NFQWS_PID 2>/dev/null; exit 0' SIGTERM SIGINT

log_info "✓ zapret2 is ready!"
log_info "  SOCKS5: 0.0.0.0:$SOCKS5_PORT"
log_info "  NFQUEUE: $NFQUEUE_NUM"
log_info "  Log level: $LOG_LEVEL"

# Wait for processes
wait $SOCKS_PID $NFQWS_PID
