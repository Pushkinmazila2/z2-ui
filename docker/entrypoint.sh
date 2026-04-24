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
    local client_ip="" dest_ip="" dest_port=""
    
    # New connection accepted
    if echo "$line" | grep -q "accept.*connection from"; then
        client_ip=$(extract_client_ip "$line")
        if [ -n "$client_ip" ]; then
            echo "$client_ip" > "$LAST_CLIENT_IP"
            log_info "🔌 New SOCKS5 connection accepted" "$client_ip"
        fi
        return
    fi
    
    # Connection established to destination
    if echo "$line" | grep -q "connect.*to"; then
        local host=$(extract_hostname "$line")
        client_ip=$(cat "$LAST_CLIENT_IP" 2>/dev/null || echo "")
        
        # Extract destination IP and port
        dest_ip=$(echo "$line" | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | tail -1)
        dest_port=$(echo "$line" | grep -oE ':[0-9]+' | tail -1 | tr -d ':')
        
        if [ -n "$host" ] && [ -n "$client_ip" ]; then
            echo "$host $client_ip $(timestamp) $dest_ip" >> "$CLIENT_MAP"
            if [ -n "$dest_ip" ] && [ -n "$dest_port" ]; then
                log_info "🌐 Connecting: $host ($dest_ip:$dest_port)" "$client_ip"
            else
                log_info "🌐 Connecting: $host" "$client_ip"
            fi
        fi
        return
    fi
    
    # Connection closed
    if echo "$line" | grep -qE "(close|disconnect|terminate)"; then
        client_ip=$(cat "$LAST_CLIENT_IP" 2>/dev/null || echo "")
        log_info "🔌 Connection closed" "$client_ip"
        return
    fi
    
    # Data transfer stats
    if echo "$line" | grep -qE "(bytes|transferred)"; then
        client_ip=$(cat "$LAST_CLIENT_IP" 2>/dev/null || echo "")
        local bytes=$(echo "$line" | grep -oE '[0-9]+ bytes' | head -1)
        if [ -n "$bytes" ]; then
            log_debug "📊 Transfer: $bytes" "$client_ip"
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
    local src_ip="" dst_ip="" src_port="" dst_port=""
    
    # Extract connection info from packet logs
    if echo "$line" | grep -qE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+ -> [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+"; then
        src_ip=$(echo "$line" | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}:[0-9]+' | head -1 | cut -d: -f1)
        src_port=$(echo "$line" | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}:[0-9]+' | head -1 | cut -d: -f2)
        dst_ip=$(echo "$line" | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}:[0-9]+' | tail -1 | cut -d: -f1)
        dst_port=$(echo "$line" | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}:[0-9]+' | tail -1 | cut -d: -f2)
        
        # Find client IP from SOCKS5 connections
        client_ip=$(grep " $dst_ip " "$CLIENT_MAP" 2>/dev/null | tail -1 | awk '{print $2}')
        [ -z "$client_ip" ] && client_ip="$src_ip"
    fi
    
    # Extract hostname from nfqws2 output
    if echo "$line" | grep -qE "(hostname|SNI|Host:)"; then
        host=$(echo "$line" | sed -nE 's/.*(hostname|SNI|Host:)[: ]*([^ ]+).*/\2/p' | head -1)
        
        if [ -n "$host" ]; then
            # Find client IP from recent connections
            client_ip=$(grep "^$host " "$CLIENT_MAP" 2>/dev/null | tail -1 | awk '{print $2}')
        fi
    fi
    
    # Packet send/receive logs
    if echo "$line" | grep -qE "(sending|sent|received|recv)"; then
        if [ "$LOG_LEVEL" = "debug" ]; then
            if [ -n "$src_ip" ] && [ -n "$dst_ip" ]; then
                log_debug "📤 $src_ip:$src_port → $dst_ip:$dst_port | $line" "$client_ip"
            else
                log_debug "📦 $line" "$client_ip"
            fi
        fi
        return
    fi
    
    # DPI bypass actions (desync, fake, split, disorder)
    if echo "$line" | grep -qE "(desync|fake|split|disorder|multisplit|multidisorder)"; then
        if [ -n "$src_ip" ] && [ -n "$dst_ip" ]; then
            log_info "🔧 DPI bypass: $src_ip:$src_port → $dst_ip:$dst_port" "$client_ip"
            [ "$LOG_LEVEL" = "debug" ] && log_debug "   Details: $line" "$client_ip"
        else
            log_info "🔧 DPI bypass applied" "$client_ip"
            [ "$LOG_LEVEL" = "debug" ] && log_debug "   $line" "$client_ip"
        fi
        return
    fi
    
    # Packet fragmentation/split logs
    if echo "$line" | grep -qE "(fragment|split|chunk)"; then
        if [ -n "$src_ip" ] && [ -n "$dst_ip" ]; then
            log_info "✂️  Packet split: $src_ip:$src_port → $dst_ip:$dst_port" "$client_ip"
        else
            log_info "✂️  Packet split" "$client_ip"
        fi
        [ "$LOG_LEVEL" = "debug" ] && log_debug "   $line" "$client_ip"
        return
    fi
    
    # TLS/QUIC handshake
    if echo "$line" | grep -qE "(TLS|QUIC|handshake|ClientHello)"; then
        if [ -n "$host" ]; then
            log_info "🔐 TLS/QUIC: $host" "$client_ip"
        fi
        [ "$LOG_LEVEL" = "debug" ] && log_debug "   $line" "$client_ip"
        return
    fi
    
    # Packet details in debug mode
    if [ "$LOG_LEVEL" = "debug" ]; then
        if echo "$line" | grep -qE "(packet|TCP|UDP)"; then
            if [ -n "$src_ip" ] && [ -n "$dst_ip" ]; then
                log_debug "📊 $src_ip:$src_port → $dst_ip:$dst_port" "$client_ip"
            else
                log_debug "📊 $line" "$client_ip"
            fi
        fi
    fi
    
    # Always log errors
    if echo "$line" | grep -qiE "(error|fail)"; then
        log_error "❌ NFQWS: $line"
    fi
}

# Configuration
log_info "Starting zapret2 SOCKS5 proxy container"
log_info "Log level: $LOG_LEVEL"

SOCKS5_PORT=${SOCKS5_PORT:-1080}
NFQUEUE_NUM=${NFQUEUE_NUM:-200}
ZAPRET_CONFIG=${ZAPRET_CONFIG:-/opt/zapret2/config}

# Load config - create default if not exists
if [ -f "$ZAPRET_CONFIG" ] && [ ! -d "$ZAPRET_CONFIG" ]; then
    log_info "✓ Loading configuration from: $ZAPRET_CONFIG"
    . "$ZAPRET_CONFIG"
    log_info "✓ Config loaded successfully"
else
    log_warn "⚠️  Configuration file not found: $ZAPRET_CONFIG"
    log_info "Creating default config file..."
    
    # Create default config
    cat > "$ZAPRET_CONFIG" <<'EOF'
# Zapret2 Configuration
# Edit via Web UI at http://localhost:8088

NFQWS2_ENABLE="1"

# Default simple strategy (will be updated via Web UI)
NFQWS2_OPT="--filter-tcp=443 --filter-l7=tls --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:repeats=2 --lua-desync=multisplit:pos=1 --bind-fix4"

MODE_FILTER="none"
DISABLE_IPV6="1"
EOF
    
    . "$ZAPRET_CONFIG"
    log_info "✓ Default config created and loaded"
    log_info "📝 Configure strategies via Web UI: http://localhost:8088"
fi

# Create proxy user
log_debug "Creating proxy user"
id -u proxyuser &>/dev/null || adduser -D -H -s /bin/false proxyuser

# Setup iptables
log_info "Setting up iptables rules (Global Mode)"
# Setup iptables
iptables -t mangle -F

# Исправляем контрольные суммы для исходящего трафика (ЧТОБЫ НЕ ВИСЛО)
iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
iptables -t mangle -A POSTROUTING -p tcp -j CHECKSUM --checksum-fill

# Маркировка и очередь (как мы делали раньше)
iptables -t mangle -A OUTPUT -m mark --mark 0x40000000/0x40000000 -j RETURN
iptables -t mangle -A OUTPUT -p tcp --dport 443 -j NFQUEUE --queue-num $NFQUEUE_NUM --queue-bypass


log_debug "iptables: all port 443 traffic redirected to NFQUEUE"

# Configure dante
log_info "Configuring dante SOCKS5 server"

# Set dante log level based on LOG_LEVEL
DANTE_LOG="error"
[ "$LOG_LEVEL" = "debug" ] && DANTE_LOG="connect disconnect"

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
    log: $DANTE_LOG
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: $DANTE_LOG
}
EOF

# Validate configuration
if [ "${NFQWS2_ENABLE:-0}" != "1" ]; then
    log_warn "⚠️  NFQWS2_ENABLE is not set to 1, enabling by default"
    NFQWS2_ENABLE="1"
fi

if [ -z "$NFQWS2_OPT" ]; then
    log_warn "⚠️  NFQWS2_OPT is not set, using minimal bypass strategy"
    NFQWS2_OPT="--filter-tcp=443 --filter-l7=tls --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:repeats=2"
    log_info "📝 Configure better strategy via Web UI: http://localhost:8088"
fi

# Prepare nfqws2 options (base + strategy from config)
# Add --queue-bypass to prevent blocking if nfqws2 fails
NFQWS_OPTS="--qnum=$NFQUEUE_NUM --queue-bypass --lua-init=@/opt/zapret2/lua/zapret-lib.lua --lua-init=@/opt/zapret2/lua/zapret-antidpi.lua $NFQWS2_OPT"

# Show loaded strategy
log_info "✓ DPI bypass strategy loaded:"
log_info "  Config: $ZAPRET_CONFIG"
log_info "  Length: ${#NFQWS2_OPT} chars"
log_debug "  Strategy: $NFQWS2_OPT"

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

# Function to start nfqws2 with auto-restart
start_nfqws2() {
    local restart_count=0
    while true; do
        log_info "Starting nfqws2 on queue $NFQUEUE_NUM (attempt $((restart_count+1)))"
        log_info "Strategy: ${NFQWS2_OPT:0:100}..."
        
        if [ "$LOG_LEVEL" = "debug" ]; then
            log_debug "Command: /usr/local/bin/nfqws2 $NFQWS_OPTS"
        fi
        
        # Run nfqws2 and filter out help text
        /usr/local/bin/nfqws2 $NFQWS_OPTS 2>&1 | while IFS= read -r line; do
            # Skip help/usage lines that start with spaces or tabs
            if echo "$line" | grep -qE '^[[:space:]]+(--|;)'; then
                continue
            fi
            process_nfqws_log "$line"
        done
        
        EXIT_CODE=$?
        restart_count=$((restart_count+1))
        
        # If exits immediately multiple times, something is wrong
        if [ $restart_count -gt 5 ]; then
            log_error "❌ nfqws2 failed to start after 5 attempts"
            log_error "Check configuration: $NFQWS2_OPT"
            log_error "Waiting 30 seconds before retry..."
            sleep 30
            restart_count=0
        else
            log_warn "⚠️  nfqws2 exited (code $EXIT_CODE), restarting in 3 seconds..."
            sleep 3
        fi
    done
}

# Verify nfqws2 binary exists and is executable
if [ ! -x "/usr/local/bin/nfqws2" ]; then
    log_error "nfqws2 binary not found or not executable!"
    log_error "Container will run in SOCKS5-only mode (no DPI bypass)"
    NFQWS2_ENABLE="0"
    SKIP_NFQWS=1
else
    log_info "✓ nfqws2 binary found at /usr/local/bin/nfqws2"
fi

# Start nfqws2 only if enabled
if [ "${SKIP_NFQWS}" != "1" ] && [ "${NFQWS2_ENABLE}" = "1" ]; then
    start_nfqws2 &
    NFQWS_PID=$!
    
    # Give nfqws2 a moment to start
    sleep 2
    
    # Check if nfqws2 is running
    if pgrep -f "nfqws2.*--qnum=$NFQUEUE_NUM" >/dev/null; then
        log_info "✓ nfqws2 process is running"
    else
        log_warn "⚠️  nfqws2 may not be running properly (check logs)"
    fi
else
    log_warn "⚠️  nfqws2 disabled, running SOCKS5-only mode"
    NFQWS_PID=""
fi

# Start web control panel
WEB_PORT=${WEB_PORT:-8088}
log_info "Starting Web Control Panel on port $WEB_PORT"
python3 /opt/zapret2/web/server.py &
WEB_PID=$!

# Statistics function
print_stats() {
    while true; do
        sleep 300  # Every 5 minutes
        local total_connections=$(wc -l < "$CLIENT_MAP" 2>/dev/null || echo 0)
        local unique_clients=$(awk '{print $2}' "$CLIENT_MAP" 2>/dev/null | sort -u | wc -l)
        local unique_hosts=$(awk '{print $1}' "$CLIENT_MAP" 2>/dev/null | sort -u | wc -l)
        
        log_info "📊 Statistics (last 5 min):"
        log_info "   Total connections: $total_connections"
        log_info "   Unique clients: $unique_clients"
        log_info "   Unique hosts: $unique_hosts"
        
        # Clear old entries (older than 5 minutes)
        find "$CLIENT_MAP" -mmin +5 -delete 2>/dev/null
    done
}

# Start statistics in background if debug mode
if [ "$LOG_LEVEL" = "debug" ]; then
    print_stats &
    STATS_PID=$!
fi

# Graceful shutdown
trap 'log_info "Shutting down..."; kill $SOCKS_PID $NFQWS_PID $WEB_PID $STATS_PID 2>/dev/null; exit 0' SIGTERM SIGINT

log_info "✓ zapret2 is ready!"
log_info "  SOCKS5: 0.0.0.0:$SOCKS5_PORT"
log_info "  Web UI: http://0.0.0.0:$WEB_PORT (admin/zapret)"
log_info "  NFQUEUE: $NFQUEUE_NUM"
log_info "  Log level: $LOG_LEVEL"
log_info "  Detailed packet logs: $([ "$LOG_LEVEL" = "debug" ] && echo "ENABLED" || echo "DISABLED")"

# Wait for processes
wait $SOCKS_PID $NFQWS_PID $WEB_PID
