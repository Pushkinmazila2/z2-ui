# Развертывание zapret2 Docker

## Сценарии развертывания

### 1. Локальная разработка и тестирование

```bash
# Сборка
docker build -t zapret2-proxy:dev .

# Запуск с debug
docker run -d \
  --name zapret2-dev \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --sysctl net.ipv4.ip_forward=1 \
  --sysctl net.ipv4.conf.all.route_localnet=1 \
  -p 1080:1080 \
  -e NFQWS2_OPT="--debug --filter-tcp=80,443 --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5" \
  zapret2-proxy:dev

# Просмотр логов
docker logs -f zapret2-dev
```

### 2. Продакшн с Docker Compose

```yaml
# docker-compose.prod.yml
version: '3.8'

services:
  zapret2:
    image: zapret2-proxy:latest
    container_name: zapret2-prod
    restart: always
    
    cap_add:
      - NET_ADMIN
      - NET_RAW
    
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.route_localnet=1
    
    ports:
      - "127.0.0.1:1080:1080"  # Только localhost
    
    environment:
      - SOCKS5_PORT=1080
      - SOCKS5_USER=${SOCKS5_USER}
      - SOCKS5_PASS=${SOCKS5_PASS}
      - NFQWS2_ENABLE=1
      - DISABLE_IPV6=1
    
    volumes:
      - ./config:/opt/zapret2/config:ro
      - ./lists:/opt/zapret2/lists:ro
      - zapret-logs:/var/log/zapret2
    
    healthcheck:
      test: ["CMD", "netstat", "-tuln", "|", "grep", "-q", ":1080"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s
    
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  zapret-logs:

networks:
  default:
    driver: bridge
```

```bash
# Создайте .env файл
cat > .env <<EOF
SOCKS5_USER=admin
SOCKS5_PASS=$(openssl rand -base64 32)
EOF

# Запуск
docker-compose -f docker-compose.prod.yml up -d
```

### 3. С singbox в одной сети

```yaml
# docker-compose.singbox.yml
version: '3.8'

services:
  zapret2:
    build: .
    container_name: zapret2
    restart: unless-stopped
    
    cap_add:
      - NET_ADMIN
      - NET_RAW
    
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.route_localnet=1
    
    networks:
      - proxy-net
    
    environment:
      - SOCKS5_PORT=1080
      - NFQWS2_ENABLE=1
    
    volumes:
      - ./config:/opt/zapret2/config:ro
      - ./lists:/opt/zapret2/lists:ro

  singbox:
    image: ghcr.io/sagernet/sing-box:latest
    container_name: singbox
    restart: unless-stopped
    
    depends_on:
      zapret2:
        condition: service_healthy
    
    networks:
      - proxy-net
    
    ports:
      - "7890:7890"  # HTTP proxy
      - "7891:7891"  # SOCKS5 proxy
    
    volumes:
      - ./singbox-config.json:/etc/sing-box/config.json:ro
    
    command: run -c /etc/sing-box/config.json

networks:
  proxy-net:
    driver: bridge
```

```json
// singbox-config.json
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "http",
      "tag": "http-in",
      "listen": "::",
      "listen_port": 7890
    },
    {
      "type": "socks",
      "tag": "socks-in",
      "listen": "::",
      "listen_port": 7891
    }
  ],
  "outbounds": [
    {
      "type": "socks",
      "tag": "zapret2",
      "server": "zapret2",
      "server_port": 1080
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "outbound": "zapret2"
      }
    ]
  }
}
```

### 4. За Nginx reverse proxy

```nginx
# /etc/nginx/streams.d/zapret2.conf
stream {
    upstream zapret2_socks {
        server 127.0.0.1:1080;
    }

    server {
        listen 1080;
        proxy_pass zapret2_socks;
        proxy_connect_timeout 1s;
    }
}
```

### 5. Systemd service для автозапуска

```ini
# /etc/systemd/system/zapret2-docker.service
[Unit]
Description=zapret2 Docker Container
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes

WorkingDirectory=/opt/zapret2

ExecStartPre=-/usr/bin/docker stop zapret2
ExecStartPre=-/usr/bin/docker rm zapret2

ExecStart=/usr/bin/docker run -d \
  --name zapret2 \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --sysctl net.ipv4.ip_forward=1 \
  --sysctl net.ipv4.conf.all.route_localnet=1 \
  -p 127.0.0.1:1080:1080 \
  -v /opt/zapret2/config:/opt/zapret2/config:ro \
  -v /opt/zapret2/lists:/opt/zapret2/lists:ro \
  --restart unless-stopped \
  zapret2-proxy:latest

ExecStop=/usr/bin/docker stop zapret2

[Install]
WantedBy=multi-user.target
```

```bash
# Установка
sudo systemctl daemon-reload
sudo systemctl enable zapret2-docker
sudo systemctl start zapret2-docker

# Проверка
sudo systemctl status zapret2-docker
```

### 6. Docker Swarm (кластер)

```yaml
# docker-stack.yml
version: '3.8'

services:
  zapret2:
    image: zapret2-proxy:latest
    
    deploy:
      replicas: 2
      update_config:
        parallelism: 1
        delay: 10s
      restart_policy:
        condition: on-failure
        delay: 5s
        max_attempts: 3
      resources:
        limits:
          cpus: '1'
          memory: 512M
        reservations:
          cpus: '0.5'
          memory: 256M
    
    cap_add:
      - NET_ADMIN
      - NET_RAW
    
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.route_localnet=1
    
    ports:
      - "1080:1080"
    
    environment:
      - SOCKS5_PORT=1080
      - NFQWS2_ENABLE=1
    
    configs:
      - source: zapret_config
        target: /opt/zapret2/config
    
    secrets:
      - socks5_credentials

configs:
  zapret_config:
    file: ./config

secrets:
  socks5_credentials:
    file: ./secrets/socks5.txt
```

```bash
# Развертывание
docker stack deploy -c docker-stack.yml zapret2

# Проверка
docker stack services zapret2
docker stack ps zapret2
```

### 7. Kubernetes (базовый)

```yaml
# k8s/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: zapret2
  namespace: proxy
spec:
  replicas: 2
  selector:
    matchLabels:
      app: zapret2
  template:
    metadata:
      labels:
        app: zapret2
    spec:
      containers:
      - name: zapret2
        image: zapret2-proxy:latest
        ports:
        - containerPort: 1080
          name: socks5
        env:
        - name: SOCKS5_PORT
          value: "1080"
        - name: NFQWS2_ENABLE
          value: "1"
        - name: SOCKS5_USER
          valueFrom:
            secretKeyRef:
              name: zapret2-credentials
              key: username
        - name: SOCKS5_PASS
          valueFrom:
            secretKeyRef:
              name: zapret2-credentials
              key: password
        securityContext:
          capabilities:
            add:
            - NET_ADMIN
            - NET_RAW
          privileged: false
        resources:
          requests:
            memory: "256Mi"
            cpu: "500m"
          limits:
            memory: "512Mi"
            cpu: "1000m"
        volumeMounts:
        - name: config
          mountPath: /opt/zapret2/config
          readOnly: true
        - name: lists
          mountPath: /opt/zapret2/lists
          readOnly: true
      volumes:
      - name: config
        configMap:
          name: zapret2-config
      - name: lists
        configMap:
          name: zapret2-lists
---
apiVersion: v1
kind: Service
metadata:
  name: zapret2
  namespace: proxy
spec:
  selector:
    app: zapret2
  ports:
  - port: 1080
    targetPort: 1080
    name: socks5
  type: ClusterIP
```

```bash
# Создание namespace
kubectl create namespace proxy

# Создание секретов
kubectl create secret generic zapret2-credentials \
  --from-literal=username=admin \
  --from-literal=password=$(openssl rand -base64 32) \
  -n proxy

# Создание ConfigMap
kubectl create configmap zapret2-config \
  --from-file=config=./config \
  -n proxy

# Развертывание
kubectl apply -f k8s/deployment.yaml

# Проверка
kubectl get pods -n proxy
kubectl logs -f deployment/zapret2 -n proxy
```

## Мониторинг и логирование

### Prometheus метрики (будущая функция)

```yaml
# docker-compose.monitoring.yml
services:
  zapret2:
    # ... основная конфигурация
    ports:
      - "1080:1080"
      - "9090:9090"  # Метрики

  prometheus:
    image: prom/prometheus:latest
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus-data:/prometheus
    ports:
      - "9091:9090"

  grafana:
    image: grafana/grafana:latest
    volumes:
      - grafana-data:/var/lib/grafana
    ports:
      - "3000:3000"
```

### Centralized logging с ELK

```yaml
services:
  zapret2:
    logging:
      driver: "fluentd"
      options:
        fluentd-address: localhost:24224
        tag: zapret2
```

## Backup и восстановление

```bash
# Backup конфигурации
tar -czf zapret2-backup-$(date +%Y%m%d).tar.gz \
  config \
  lists/ \
  docker-compose.yml

# Восстановление
tar -xzf zapret2-backup-20260423.tar.gz
docker-compose up -d
```

## Обновление

```bash
# Пересборка образа
docker build -t zapret2-proxy:latest .

# Обновление с минимальным downtime
docker-compose up -d --no-deps --build zapret2

# Откат при проблемах
docker-compose down
docker run -d \
  --name zapret2 \
  ... \
  zapret2-proxy:previous-version
```

## Безопасность в продакшене

1. **Используйте аутентификацию**
```bash
SOCKS5_USER=admin
SOCKS5_PASS=$(openssl rand -base64 32)
```

2. **Ограничьте доступ к порту**
```yaml
ports:
  - "127.0.0.1:1080:1080"  # Только localhost
```

3. **Используйте firewall**
```bash
# UFW
sudo ufw allow from 10.0.0.0/8 to any port 1080
sudo ufw deny 1080
```

4. **Регулярно обновляйте**
```bash
# Автообновление через cron
0 3 * * * cd /opt/zapret2 && docker-compose pull && docker-compose up -d
```

5. **Мониторьте логи**
```bash
# Настройте алерты на ошибки
docker logs zapret2 2>&1 | grep -i error
```

## Производительность

### Оптимизация для высоких нагрузок

```yaml
services:
  zapret2:
    deploy:
      resources:
        limits:
          cpus: '2'
          memory: 1G
    
    environment:
      # Упрощенные стратегии
      - NFQWS2_OPT=--filter-tcp=443 --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5
```

### Масштабирование

```bash
# Несколько инстансов за load balancer
docker-compose up -d --scale zapret2=3
```

## Troubleshooting в продакшене

```bash
# Проверка здоровья
curl --socks5 localhost:1080 https://www.google.com

# Статистика контейнера
docker stats zapret2

# Проверка сети
docker exec zapret2 ip addr
docker exec zapret2 ip route

# Проверка iptables
docker exec zapret2 iptables-save

# Дамп трафика
docker exec zapret2 tcpdump -i any -w /tmp/dump.pcap
docker cp zapret2:/tmp/dump.pcap .
```