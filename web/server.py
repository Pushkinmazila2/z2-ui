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
import threading
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import parse_qs, urlparse
import hashlib
import secrets
from collections import deque

# Configuration
CONFIG_FILE = os.getenv('ZAPRET_CONFIG', '/opt/zapret2/config')
STRATEGIES_FILE = os.path.join(os.path.dirname(__file__), 'strategies.json')
AUTH_FILE = os.path.join(os.path.dirname(__file__), '.htpasswd')
PORT = 8088

# Log buffer (last 500 lines)
log_buffer = deque(maxlen=500)
log_lock = threading.Lock()

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

def log_message(msg, level='INFO'):
    """Log message to buffer and stdout"""
    timestamp = time.strftime('%Y-%m-%d %H:%M:%S')
    log_line = f'[{timestamp}] [{level}] {msg}'
    
    with log_lock:
        log_buffer.append(log_line)
    
    print(log_line, flush=True)

def set_strategy(strategy_config):
    """Update config file with new strategy"""
    log_message(f'Updating config file: {CONFIG_FILE}')
    
    if not os.path.exists(CONFIG_FILE):
        log_message(f'Config file not found: {CONFIG_FILE}', 'ERROR')
        return False
    
    try:
        with open(CONFIG_FILE, 'r', encoding='utf-8') as f:
            lines = f.readlines()
        
        with open(CONFIG_FILE, 'w', encoding='utf-8') as f:
            for line in lines:
                if line.startswith('NFQWS2_OPT='):
                    f.write(f'NFQWS2_OPT="{strategy_config}"\n')
                    log_message('Strategy updated in config')
                else:
                    f.write(line)
        
        log_message('Config file saved successfully')
        return True
    except Exception as e:
        log_message(f'Failed to update config: {str(e)}', 'ERROR')
        return False

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
        elif self.path == '/api/logs':
            self.api_get_logs()
        else:
            self.send_error(404)
    
    def do_POST(self):
        # Check auth
        if not check_auth(self.headers.get('Authorization')):
            self.send_response(401)
            self.send_header('WWW-Authenticate', 'Basic realm="Zapret Control Panel"')
            self.end_headers()
            return
        
        try:
            if self.path == '/api/apply':
                self.api_apply_strategy()
            elif self.path == '/api/save':
                self.api_save_strategy()
            elif self.path == '/api/delete':
                self.api_delete_strategy()
            else:
                self.send_error(404)
        except Exception as e:
            self.send_json({'success': False, 'message': f'Server error: {str(e)}'})
    
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
        .strategies { display: grid; gap: 15px; margin-bottom: 20px; }
        .strategy { background: #1a1a1a; padding: 20px; border-radius: 8px; cursor: pointer; transition: all 0.2s; border: 2px solid transparent; position: relative; }
        .strategy:hover { background: #252525; }
        .strategy.active { border-color: #4CAF50; background: #1e2a1e; }
        .strategy.selected { border-color: #2196F3; }
        .strategy h3 { font-size: 16px; margin-bottom: 8px; font-weight: 600; }
        .strategy p { font-size: 13px; color: #999; margin-bottom: 10px; }
        .strategy code { display: block; background: #0a0a0a; padding: 10px; border-radius: 4px; font-size: 11px; overflow-x: auto; white-space: pre-wrap; word-break: break-all; }
        .strategy .actions { position: absolute; top: 15px; right: 15px; display: none; gap: 8px; }
        .strategy:hover .actions { display: flex; }
        .strategy .actions button { background: #333; border: none; color: #fff; padding: 6px 12px; border-radius: 4px; cursor: pointer; font-size: 12px; }
        .strategy .actions button:hover { background: #444; }
        .strategy .actions .delete { background: #d32f2f; }
        .strategy .actions .delete:hover { background: #b71c1c; }
        .btn { background: #4CAF50; color: white; border: none; padding: 12px 24px; border-radius: 6px; cursor: pointer; font-size: 14px; font-weight: 500; margin-right: 10px; }
        .btn:hover { background: #45a049; }
        .btn:disabled { background: #333; cursor: not-allowed; }
        .btn.secondary { background: #2196F3; }
        .btn.secondary:hover { background: #1976D2; }
        .message { padding: 12px; border-radius: 6px; margin-top: 15px; display: none; }
        .message.success { background: #1e4620; color: #4CAF50; display: block; }
        .message.error { background: #4a1a1a; color: #f44336; display: block; }
        .modal { display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.8); z-index: 1000; }
        .modal.show { display: flex; align-items: center; justify-content: center; }
        .modal-content { background: #1a1a1a; padding: 30px; border-radius: 8px; max-width: 600px; width: 90%; }
        .modal-content h2 { margin-bottom: 20px; font-size: 20px; }
        .form-group { margin-bottom: 15px; }
        .form-group label { display: block; margin-bottom: 5px; font-size: 14px; color: #999; }
        .form-group input, .form-group textarea { width: 100%; background: #0a0a0a; border: 1px solid #333; color: #e0e0e0; padding: 10px; border-radius: 4px; font-family: inherit; font-size: 14px; }
        .form-group textarea { min-height: 100px; font-family: 'Courier New', monospace; font-size: 12px; }
        .modal-actions { display: flex; gap: 10px; margin-top: 20px; }
        .logs-panel { background: #0a0a0a; border-radius: 8px; padding: 15px; margin-top: 20px; max-height: 400px; overflow-y: auto; font-family: 'Courier New', monospace; font-size: 12px; }
        .logs-panel h3 { font-size: 16px; margin-bottom: 10px; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; }
        .log-line { padding: 4px 0; border-bottom: 1px solid #1a1a1a; }
        .log-line:last-child { border-bottom: none; }
        .log-line.error { color: #f44336; }
        .log-line.warn { color: #FFC107; }
        .log-line.info { color: #4CAF50; }
        .log-controls { display: flex; gap: 10px; margin-bottom: 10px; align-items: center; }
        .log-controls button { background: #333; border: none; color: #fff; padding: 6px 12px; border-radius: 4px; cursor: pointer; font-size: 12px; }
        .log-controls button:hover { background: #444; }
        .log-controls .auto-scroll { display: flex; align-items: center; gap: 5px; font-size: 12px; color: #999; }
        .log-controls input[type=checkbox] { cursor: pointer; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🛡️ Zapret Control Panel</h1>
        
        <div class="status" id="status">
            <strong>Текущая стратегия:</strong> <span id="current">Загрузка...</span>
        </div>
        
        <div class="strategies" id="strategies"></div>
        
        <div>
            <button class="btn" id="applyBtn" onclick="applyStrategy()" disabled>Применить стратегию</button>
            <button class="btn secondary" onclick="showAddModal()">+ Добавить стратегию</button>
        </div>
        
        <div class="message" id="message"></div>
        
        <div class="logs-panel">
            <div class="log-controls">
                <h3 style="margin: 0; flex: 1;">📋 Логи</h3>
                <label class="auto-scroll">
                    <input type="checkbox" id="autoScroll" checked>
                    Авто-прокрутка
                </label>
                <button onclick="clearLogs()">Очистить</button>
                <button onclick="refreshLogs()">Обновить</button>
            </div>
            <div id="logs"></div>
        </div>
    </div>
    
    <div class="modal" id="addModal">
        <div class="modal-content">
            <h2>Добавить стратегию</h2>
            <div class="form-group">
                <label>Ключ (латиница, цифры, _)</label>
                <input type="text" id="strategyKey" placeholder="my_custom_strategy">
            </div>
            <div class="form-group">
                <label>Название</label>
                <input type="text" id="strategyName" placeholder="Моя стратегия">
            </div>
            <div class="form-group">
                <label>Описание</label>
                <input type="text" id="strategyDesc" placeholder="Описание стратегии">
            </div>
            <div class="form-group">
                <label>Конфигурация NFQWS2_OPT</label>
                <textarea id="strategyConfig" placeholder="--filter-tcp=443 --lua-desync=..."></textarea>
            </div>
            <div class="modal-actions">
                <button class="btn" onclick="saveStrategy()">Сохранить</button>
                <button class="btn secondary" onclick="closeModal()">Отмена</button>
            </div>
        </div>
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
            
            const defaultKeys = ['youtube_aggressive', 'simple_fake', 'multisplit'];
            
            for (const [key, strategy] of Object.entries(strategies)) {
                const div = document.createElement('div');
                div.className = 'strategy';
                if (strategy.config === currentConfig) {
                    div.classList.add('active');
                }
                div.onclick = () => selectStrategy(key);
                
                const isCustom = !defaultKeys.includes(key);
                const deleteBtn = isCustom ? `<button class="delete" onclick="deleteStrategy('${key}', event)">Удалить</button>` : '';
                
                div.innerHTML = `
                    <div class="actions">
                        ${deleteBtn}
                    </div>
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
                el.classList.remove('selected');
            });
            event.currentTarget.classList.add('selected');
            document.getElementById('applyBtn').disabled = false;
        }
        
        function showAddModal() {
            document.getElementById('addModal').classList.add('show');
        }
        
        function closeModal() {
            document.getElementById('addModal').classList.remove('show');
            document.getElementById('strategyKey').value = '';
            document.getElementById('strategyName').value = '';
            document.getElementById('strategyDesc').value = '';
            document.getElementById('strategyConfig').value = '';
        }
        
        async function saveStrategy() {
            const key = document.getElementById('strategyKey').value.trim();
            const name = document.getElementById('strategyName').value.trim();
            const description = document.getElementById('strategyDesc').value.trim();
            const config = document.getElementById('strategyConfig').value.trim();
            
            if (!key || !name || !config) {
                showMessage('Заполните все обязательные поля', 'error');
                return;
            }
            
            try {
                const res = await fetch('/api/save', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ key, name, description, config })
                });
                
                const data = await res.json();
                
                if (data.success) {
                    showMessage('Стратегия сохранена', 'success');
                    closeModal();
                    loadData();
                } else {
                    showMessage('Ошибка: ' + data.message, 'error');
                }
            } catch (e) {
                showMessage('Ошибка сохранения', 'error');
            }
        }
        
        async function deleteStrategy(key, event) {
            event.stopPropagation();
            
            if (!confirm('Удалить стратегию "' + strategies[key].name + '"?')) {
                return;
            }
            
            try {
                const res = await fetch('/api/delete', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ key })
                });
                
                const data = await res.json();
                
                if (data.success) {
                    showMessage('Стратегия удалена', 'success');
                    loadData();
                } else {
                    showMessage('Ошибка: ' + data.message, 'error');
                }
            } catch (e) {
                showMessage('Ошибка удаления', 'error');
            }
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
        
        // Logs functionality
        let autoScroll = true;
        
        async function refreshLogs() {
            try {
                const res = await fetch('/api/logs');
                const data = await res.json();
                const logsDiv = document.getElementById('logs');
                
                logsDiv.innerHTML = data.logs.map(line => {
                    let className = 'log-line';
                    if (line.includes('[ERROR]')) className += ' error';
                    else if (line.includes('[WARN]')) className += ' warn';
                    else if (line.includes('[INFO]')) className += ' info';
                    return `<div class="${className}">${line}</div>`;
                }).join('');
                
                if (autoScroll) {
                    logsDiv.parentElement.scrollTop = logsDiv.parentElement.scrollHeight;
                }
            } catch (e) {
                console.error('Failed to refresh logs:', e);
            }
        }
        
        function clearLogs() {
            document.getElementById('logs').innerHTML = '<div class="log-line">Логи очищены</div>';
        }
        
        document.getElementById('autoScroll').addEventListener('change', (e) => {
            autoScroll = e.target.checked;
        });
        
        // Auto-refresh logs every 2 seconds
        setInterval(refreshLogs, 2000);
        refreshLogs();
        
        // Log to console
        const originalFetch = window.fetch;
        window.fetch = function(...args) {
            console.log('[FETCH]', args[0]);
            return originalFetch.apply(this, args)
                .then(response => {
                    console.log('[RESPONSE]', args[0], response.status);
                    return response;
                })
                .catch(error => {
                    console.error('[FETCH ERROR]', args[0], error);
                    throw error;
                });
        };
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
    
    def api_get_logs(self):
        with log_lock:
            logs = list(log_buffer)
        self.send_json({'logs': logs})
    
    def api_apply_strategy(self):
        try:
            content_length = int(self.headers.get('Content-Length', 0))
            if content_length == 0:
                log_message('Empty request received', 'WARN')
                self.send_json({'success': False, 'message': 'Empty request'})
                return
                
            post_data = self.rfile.read(content_length)
            data = json.loads(post_data.decode('utf-8'))
            
            strategy_key = data.get('strategy')
            log_message(f'Applying strategy: {strategy_key}')
            
            strategies = load_strategies()
            
            if strategy_key not in strategies:
                log_message(f'Strategy not found: {strategy_key}', 'ERROR')
                self.send_json({'success': False, 'message': 'Стратегия не найдена'})
                return
            
            strategy_config = strategies[strategy_key]['config']
            log_message(f'Strategy config length: {len(strategy_config)} chars')
            
            if not set_strategy(strategy_config):
                self.send_json({'success': False, 'message': 'Не удалось обновить конфиг'})
                return
            
            success, message = restart_service()
            log_message(f'Restart result: {message}')
            self.send_json({'success': success, 'message': message})
        except Exception as e:
            log_message(f'Apply strategy error: {str(e)}', 'ERROR')
            self.send_json({'success': False, 'message': f'Error: {str(e)}'})
    
    def api_save_strategy(self):
        try:
            content_length = int(self.headers.get('Content-Length', 0))
            post_data = self.rfile.read(content_length)
            data = json.loads(post_data.decode('utf-8'))
            
            strategy_key = data.get('key', '').strip()
            strategy_name = data.get('name', '').strip()
            strategy_desc = data.get('description', '').strip()
            strategy_config = data.get('config', '').strip()
            
            log_message(f'Saving strategy: {strategy_key}')
            
            if not strategy_key or not strategy_name or not strategy_config:
                log_message('Missing required fields', 'WARN')
                self.send_json({'success': False, 'message': 'Заполните все поля'})
                return
            
            # Validate key format
            if not strategy_key.replace('_', '').isalnum():
                log_message(f'Invalid key format: {strategy_key}', 'WARN')
                self.send_json({'success': False, 'message': 'Ключ может содержать только буквы, цифры и _'})
                return
            
            strategies = load_strategies()
            strategies[strategy_key] = {
                'name': strategy_name,
                'description': strategy_desc,
                'config': strategy_config
            }
            
            save_strategies(strategies)
            log_message(f'Strategy saved: {strategy_key}')
            self.send_json({'success': True, 'message': 'Стратегия сохранена'})
        except Exception as e:
            log_message(f'Save strategy error: {str(e)}', 'ERROR')
            self.send_json({'success': False, 'message': f'Error: {str(e)}'})
    
    def api_delete_strategy(self):
        try:
            content_length = int(self.headers.get('Content-Length', 0))
            post_data = self.rfile.read(content_length)
            data = json.loads(post_data.decode('utf-8'))
            
            strategy_key = data.get('key')
            log_message(f'Deleting strategy: {strategy_key}')
            
            strategies = load_strategies()
            
            if strategy_key not in strategies:
                log_message(f'Strategy not found: {strategy_key}', 'WARN')
                self.send_json({'success': False, 'message': 'Стратегия не найдена'})
                return
            
            del strategies[strategy_key]
            save_strategies(strategies)
            log_message(f'Strategy deleted: {strategy_key}')
            self.send_json({'success': True, 'message': 'Стратегия удалена'})
        except Exception as e:
            log_message(f'Delete strategy error: {str(e)}', 'ERROR')
            self.send_json({'success': False, 'message': f'Error: {str(e)}'})
    
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
        log_message(f'Created default auth: admin / {default_password}')
        log_message(f'Change password using: python3 /opt/zapret2/web/change_password.py')
    else:
        log_message('Auth file exists')

def main():
    # Ensure web directory exists
    os.makedirs(os.path.dirname(os.path.abspath(__file__)), exist_ok=True)
    
    log_message('Starting Zapret Web Control Panel')
    log_message(f'Config file: {CONFIG_FILE}')
    log_message(f'Strategies file: {STRATEGIES_FILE}')
    
    # Create default strategies file
    if not os.path.exists(STRATEGIES_FILE):
        log_message('Creating default strategies file')
        save_strategies(DEFAULT_STRATEGIES)
    else:
        log_message('Strategies file exists')
    
    # Create default auth
    create_default_auth()
    
    # Check config file
    if os.path.exists(CONFIG_FILE):
        log_message(f'Config file found: {CONFIG_FILE}')
        # Check if writable
        if os.access(CONFIG_FILE, os.W_OK):
            log_message('Config file is writable')
        else:
            log_message('WARNING: Config file is READ-ONLY! Mount with :rw flag', 'WARN')
    else:
        log_message(f'WARNING: Config file not found: {CONFIG_FILE}', 'WARN')
    
    server = HTTPServer(('0.0.0.0', PORT), ZapretHandler)
    log_message(f'Web UI started on http://0.0.0.0:{PORT}')
    log_message('Default credentials: admin / zapret')
    log_message('Ready to accept connections')
    
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log_message('Shutting down...')
        server.shutdown()

if __name__ == '__main__':
    main()