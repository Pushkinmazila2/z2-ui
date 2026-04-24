#!/usr/bin/env python3
"""
Zapret2 Web Control Panel
Lightweight web interface for managing DPI bypass strategies
"""

import os
import sys
import json
import base64
import subprocess
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import parse_qs, urlparse
import hashlib
import secrets

# Configuration
CONFIG_FILE = os.getenv('ZAPRET_CONFIG', '/opt/zapret2/config')
STRATEGIES_FILE = os.path.join(os.path.dirname(__file__), 'strategies.json')
AUTH_FILE = os.path.join(os.path.dirname(__file__), '.htpasswd')
PORT = 8088

# Default strategies
DEFAULT_STRATEGIES = {
    "youtube_aggressive": {
        "name": "YouTube Aggressive",
        "description": "Агрессивная стратегия для YouTube и Google сервисов",
        "config": '--filter-tcp=443 --filter-l7=tls --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:repeats=11:tls_mod=rnd,dupsid,sni=www.google.com --lua-desync=multidisorder:pos=1,midsld --new --filter-udp=443 --filter-l7=quic --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=11'
    },
    "simple_fake": {
        "name": "Simple Fake",
        "description": "Простая стратегия с fake пакетами",
        "config": '--filter-tcp=443 --filter-l7=tls --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:repeats=6'
    },
    "multisplit": {
        "name": "Multisplit",
        "description": "Стратегия с разделением пакетов",
        "config": '--filter-tcp=443 --filter-l7=tls --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:repeats=2 --lua-desync=multisplit:pos=1 --bind-fix4'
    }
}

def load_strategies():
    """Load strategies from file or create default"""
    if os.path.exists(STRATEGIES_FILE):
        with open(STRATEGIES_FILE, 'r', encoding='utf-8') as f:
            return json.load(f)
    return DEFAULT_STRATEGIES

def save_strategies(strategies):
    """Save strategies to file"""
    with open(STRATEGIES_FILE, 'w', encoding='utf-8') as f:
        json.dump(strategies, f, ensure_ascii=False, indent=2)

def get_current_strategy():
    """Read current NFQWS2_OPT from config"""
    if not os.path.exists(CONFIG_FILE):
        return None
    
    with open(CONFIG_FILE, 'r', encoding='utf-8') as f:
        for line in f:
            if line.startswith('NFQWS2_OPT='):
                return line.split('=', 1)[1].strip().strip('"')
    return None

def set_strategy(strategy_config):
    """Update config file with new strategy"""
    if not os.path.exists(CONFIG_FILE):
        return False
    
    with open(CONFIG_FILE, 'r', encoding='utf-8') as f:
        lines = f.readlines()
    
    with open(CONFIG_FILE, 'w', encoding='utf-8') as f:
        for line in lines:
            if line.startswith('NFQWS2_OPT='):
                f.write(f'NFQWS2_OPT="{strategy_config}"\n')
            else:
                f.write(line)
    
    return True

def restart_service():
    """Restart zapret2 service (Docker mode)"""
    # In Docker, we need to restart the container or send signal to processes
    # For now, just return success - user needs to restart container manually
    # Or we can implement process restart via supervisord/s6
    return True, "Конфиг обновлен. Перезапустите контейнер: docker restart zapret2-proxy"

def check_auth(auth_header):
    """Check HTTP Basic Auth"""
    if not os.path.exists(AUTH_FILE):
        return True  # No auth file = no auth required
    
    if not auth_header or not auth_header.startswith('Basic '):
        return False
    
    try:
        credentials = base64.b64decode(auth_header[6:]).decode('utf-8')
        username, password = credentials.split(':', 1)
        
        with open(AUTH_FILE, 'r') as f:
            for line in f:
                stored_user, stored_hash = line.strip().split(':', 1)
                if stored_user == username:
                    # Simple SHA256 hash check
                    password_hash = hashlib.sha256(password.encode()).hexdigest()
                    return password_hash == stored_hash
        return False
    except:
        return False

class ZapretHandler(BaseHTTPRequestHandler):
    
    def do_GET(self):
        # Check auth
        if not check_auth(self.headers.get('Authorization')):
            self.send_response(401)
            self.send_header('WWW-Authenticate', 'Basic realm="Zapret Control Panel"')
            self.end_headers()
            return
        
        if self.path == '/' or self.path == '/index.html':
            self.serve_index()
        elif self.path == '/api/strategies':
            self.api_get_strategies()
        elif self.path == '/api/current':
            self.api_get_current()
        else:
            self.send_error(404)
    
    def do_POST(self):
        # Check auth
        if not check_auth(self.headers.get('Authorization')):
            self.send_response(401)
            self.send_header('WWW-Authenticate', 'Basic realm="Zapret Control Panel"')
            self.end_headers()
            return
        
        if self.path == '/api/apply':
            self.api_apply_strategy()
        elif self.path == '/api/save':
            self.api_save_strategy()
        else:
            self.send_error(404)
    
    def serve_index(self):
        html = """<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Zapret Control Panel</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #0f0f0f; color: #e0e0e0; padding: 20px; }
        .container { max-width: 900px; margin: 0 auto; }
        h1 { margin-bottom: 30px; font-size: 24px; font-weight: 600; }
        .status { background: #1a1a1a; padding: 15px; border-radius: 8px; margin-bottom: 20px; border-left: 3px solid #4CAF50; }
        .status.loading { border-color: #FFC107; }
        .strategies { display: grid; gap: 15px; }
        .strategy { background: #1a1a1a; padding: 20px; border-radius: 8px; cursor: pointer; transition: all 0.2s; border: 2px solid transparent; }
        .strategy:hover { background: #252525; }
        .strategy.active { border-color: #4CAF50; background: #1e2a1e; }
        .strategy h3 { font-size: 16px; margin-bottom: 8px; font-weight: 600; }
        .strategy p { font-size: 13px; color: #999; margin-bottom: 10px; }
        .strategy code { display: block; background: #0a0a0a; padding: 10px; border-radius: 4px; font-size: 11px; overflow-x: auto; white-space: pre-wrap; word-break: break-all; }
        .btn { background: #4CAF50; color: white; border: none; padding: 12px 24px; border-radius: 6px; cursor: pointer; font-size: 14px; font-weight: 500; margin-top: 20px; }
        .btn:hover { background: #45a049; }
        .btn:disabled { background: #333; cursor: not-allowed; }
        .message { padding: 12px; border-radius: 6px; margin-top: 15px; display: none; }
        .message.success { background: #1e4620; color: #4CAF50; display: block; }
        .message.error { background: #4a1a1a; color: #f44336; display: block; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🛡️ Zapret Control Panel</h1>
        
        <div class="status" id="status">
            <strong>Текущая стратегия:</strong> <span id="current">Загрузка...</span>
        </div>
        
        <div class="strategies" id="strategies"></div>
        
        <button class="btn" id="applyBtn" onclick="applyStrategy()" disabled>Применить стратегию</button>
        
        <div class="message" id="message"></div>
    </div>
    
    <script>
        let strategies = {};
        let selectedStrategy = null;
        let currentConfig = null;
        
        async function loadData() {
            try {
                const [stratRes, currRes] = await Promise.all([
                    fetch('/api/strategies'),
                    fetch('/api/current')
                ]);
                
                strategies = await stratRes.json();
                const current = await currRes.json();
                currentConfig = current.config;
                
                renderStrategies();
                updateCurrentStatus();
            } catch (e) {
                showMessage('Ошибка загрузки данных', 'error');
            }
        }
        
        function renderStrategies() {
            const container = document.getElementById('strategies');
            container.innerHTML = '';
            
            for (const [key, strategy] of Object.entries(strategies)) {
                const div = document.createElement('div');
                div.className = 'strategy';
                if (strategy.config === currentConfig) {
                    div.classList.add('active');
                }
                div.onclick = () => selectStrategy(key);
                
                div.innerHTML = `
                    <h3>${strategy.name}</h3>
                    <p>${strategy.description}</p>
                    <code>${strategy.config}</code>
                `;
                
                container.appendChild(div);
            }
        }
        
        function selectStrategy(key) {
            selectedStrategy = key;
            document.querySelectorAll('.strategy').forEach(el => {
                el.style.borderColor = el.querySelector('h3').textContent === strategies[key].name ? '#2196F3' : 'transparent';
            });
            document.getElementById('applyBtn').disabled = false;
        }
        
        function updateCurrentStatus() {
            const currentEl = document.getElementById('current');
            const matchingStrategy = Object.values(strategies).find(s => s.config === currentConfig);
            currentEl.textContent = matchingStrategy ? matchingStrategy.name : 'Пользовательская конфигурация';
        }
        
        async function applyStrategy() {
            if (!selectedStrategy) return;
            
            const btn = document.getElementById('applyBtn');
            btn.disabled = true;
            btn.textContent = 'Применение...';
            
            try {
                const res = await fetch('/api/apply', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ strategy: selectedStrategy })
                });
                
                const data = await res.json();
                
                if (data.success) {
                    showMessage('Стратегия применена и сервис перезапущен', 'success');
                    currentConfig = strategies[selectedStrategy].config;
                    renderStrategies();
                    updateCurrentStatus();
                } else {
                    showMessage('Ошибка: ' + data.message, 'error');
                }
            } catch (e) {
                showMessage('Ошибка применения стратегии', 'error');
            } finally {
                btn.disabled = false;
                btn.textContent = 'Применить стратегию';
            }
        }
        
        function showMessage(text, type) {
            const msg = document.getElementById('message');
            msg.textContent = text;
            msg.className = 'message ' + type;
            setTimeout(() => msg.style.display = 'none', 5000);
        }
        
        loadData();
    </script>
</body>
</html>"""
        
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()
        self.wfile.write(html.encode('utf-8'))
    
    def api_get_strategies(self):
        strategies = load_strategies()
        self.send_json(strategies)
    
    def api_get_current(self):
        current = get_current_strategy()
        self.send_json({'config': current})
    
    def api_apply_strategy(self):
        content_length = int(self.headers['Content-Length'])
        post_data = self.rfile.read(content_length)
        data = json.loads(post_data.decode('utf-8'))
        
        strategy_key = data.get('strategy')
        strategies = load_strategies()
        
        if strategy_key not in strategies:
            self.send_json({'success': False, 'message': 'Стратегия не найдена'})
            return
        
        strategy_config = strategies[strategy_key]['config']
        
        if not set_strategy(strategy_config):
            self.send_json({'success': False, 'message': 'Не удалось обновить конфиг'})
            return
        
        success, message = restart_service()
        self.send_json({'success': success, 'message': message})
    
    def send_json(self, data):
        self.send_response(200)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.end_headers()
        self.wfile.write(json.dumps(data, ensure_ascii=False).encode('utf-8'))
    
    def log_message(self, format, *args):
        pass  # Suppress logs

def create_default_auth():
    """Create default auth file if it doesn't exist"""
    if not os.path.exists(AUTH_FILE):
        # Default: admin / zapret
        default_password = 'zapret'
        password_hash = hashlib.sha256(default_password.encode()).hexdigest()
        with open(AUTH_FILE, 'w') as f:
            f.write(f'admin:{password_hash}\n')
        print(f"Created default auth file: admin / {default_password}")
        print(f"Change password in: {AUTH_FILE}")

def main():
    # Ensure web directory exists
    os.makedirs(os.path.dirname(os.path.abspath(__file__)), exist_ok=True)
    
    # Create default strategies file
    if not os.path.exists(STRATEGIES_FILE):
        save_strategies(DEFAULT_STRATEGIES)
    
    # Create default auth
    create_default_auth()
    
    server = HTTPServer(('0.0.0.0', PORT), ZapretHandler)
    print(f"Zapret Control Panel running on http://0.0.0.0:{PORT}")
    print(f"Default credentials: admin / zapret")
    
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()

if __name__ == '__main__':
    main()