# zapret2 Docker Container

Контейнер zapret2 с поддержкой SOCKS5 прокси для обхода DPI.

## Особенности

- ✅ Полная изоляция от хост-системы
- ✅ SOCKS5 прокси сервер на порту 1080
- ✅ Поддержка всех стратегий zapret2/nfqws2
- ✅ Интеграция с singbox и другими прокси
- ✅ Настраиваемые lua скрипты
- ✅ Поддержка hostlist'ов
- ✅ Минимальный размер образа (Alpine Linux)

## Быстрый старт

### 1. Сборка образа

```bash
docker build -t zapret2-proxy .
```

### 2. Запуск контейнера

#### Простой запуск

```bash
docker run -d \
  --name zapret2 \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  -p 1080:1080 \
  zapret2-proxy
```

#### С docker-compose

```bash
docker-compose up -d
```

### 3. Проверка работы

```bash
# Проверить статус
docker ps

# Посмотреть логи
docker logs -f zapret2

# Проверить SOCKS5 порт
curl --socks5 localhost:1080 https://www.google.com
```

## Конфигурация

### Переменные окружения

| Переменная | Описание | По умолчанию |
|------------|----------|-------------|
| `SOCKS5_PORT` | Порт SOCKS5 прокси | `1080` |
| `SOCKS5_USER` | Имя пользователя для аутентификации | не установлено |
| `SOCKS5_PASS` | Пароль для аутентификации | не установлено |
| `NFQUEUE_NUM` | Номер очереди NFQUEUE | `200` |
| `NFQWS2_ENABLE` | Включить nfqws2 | `1` |
| `DISABLE_IPV6` | Отключить IPv6 | `1` |
| `ZAPRET_CONFIG` | Путь к конфигу zapret2 | `/opt/zapret2/config` |

### Пример с аутентификацией

```yaml
services:
  zapret2:
    environment:
      - SOCKS5_USER=myuser
      - SOCKS5_PASS=mypassword
```

### Кастомная конфигурация

1. Создайте файл `config` на основе `config.default`
2. Настройте параметры `NFQWS2_OPT`
3. Примонтируйте в контейнер:

```yaml
volumes:
  - ./config:/opt/zapret2/config:ro
```

### Пример конфигурации для разных сценариев

#### Базовая стратегия (HTTP + HTTPS)

```bash
NFQWS2_ENABLE=1
NFQWS2_OPT="
--filter-tcp=80,443 --filter-l7=http,tls
--out-range=-d10
--payload=http_req --lua-desync=fake:blob=fake_default_http:tcp_md5
--payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:repeats=6 --lua-desync=multidisorder:pos=midsld
"
```

#### Агрессивная стратегия для YouTube

```bash
NFQWS2_ENABLE=1
NFQWS2_OPT="
--filter-tcp=443 --filter-l7=tls --hostlist=/opt/zapret2/lists/youtube.txt
--out-range=-d10
--payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:repeats=11:tls_mod=rnd,dupsid,sni=www.google.com --lua-desync=multidisorder:pos=1,midsld
"
```

#### QUIC поддержка

```bash
NFQWS2_ENABLE=1
NFQWS2_OPT="
--filter-udp=443 --filter-l7=quic
--payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=11
"
```

## Интеграция с singbox

### 1. Конфигурация singbox

Создайте `singbox-config.json`:

```json
{
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

### 2. Docker Compose с singbox

```yaml
version: '3.8'

services:
  zapret2:
    build: .
    cap_add:
      - NET_ADMIN
      - NET_RAW
    ports:
      - "1080:1080"

  singbox:
    image: ghcr.io/sagernet/sing-box:latest
    depends_on:
      - zapret2
    volumes:
      - ./singbox-config.json:/etc/sing-box/config.json:ro
    ports:
      - "7890:7890"
    command: run -c /etc/sing-box/config.json
```

### 3. Запуск

```bash
docker-compose up -d
```

Теперь singbox будет направлять весь трафик через zapret2!

## Hostlist'ы

### Использование готовых списков

```bash
# Создайте директорию для списков
mkdir -p lists

# Скачайте список (например, для YouTube)
echo "youtube.com" > lists/youtube.txt
echo "googlevideo.com" >> lists/youtube.txt
echo "ytimg.com" >> lists/youtube.txt
```

### Монтирование в контейнер

```yaml
volumes:
  - ./lists:/opt/zapret2/lists:ro
```

### Использование в конфигурации

```bash
NFQWS2_OPT="
--filter-tcp=443 --hostlist=/opt/zapret2/lists/youtube.txt
--payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5
"
```

## Отладка

### Включить debug логи

Добавьте `--debug` в `NFQWS2_OPT`:

```bash
NFQWS2_OPT="--debug --filter-tcp=80,443 ..."
```

### Просмотр логов

```bash
# Логи контейнера
docker logs -f zapret2

# Логи nfqws2
docker exec zapret2 tail -f /var/log/zapret2/nfqws.log
```

### Проверка iptables правил

```bash
docker exec zapret2 iptables -t nat -L -n -v
docker exec zapret2 iptables -t mangle -L -n -v
```

### Тест SOCKS5 прокси

```bash
# С curl
curl --socks5 localhost:1080 https://www.google.com

# С wget
wget -e use_proxy=yes -e socks_proxy=localhost:1080 https://www.google.com

# Проверка с аутентификацией
curl --socks5 user:pass@localhost:1080 https://www.google.com
```

## Требования

- Docker 20.10+
- Docker Compose 1.29+ (опционально)
- Хост с поддержкой iptables и NFQUEUE

## Ограничения

- Контейнер требует привилегий `NET_ADMIN` и `NET_RAW`
- Не работает в rootless режиме Docker
- Требуется ядро Linux с поддержкой netfilter_queue

## Производительность

- Минимальное потребление RAM: ~50MB
- CPU: зависит от объема трафика и сложности стратегий
- Рекомендуется для систем с 512MB+ RAM

## Безопасность

- Используйте аутентификацию SOCKS5 в продакшене
- Ограничьте доступ к порту 1080 через firewall
- Регулярно обновляйте образ

## Troubleshooting

### Контейнер не стартует

```bash
# Проверьте логи
docker logs zapret2

# Проверьте capabilities
docker inspect zapret2 | grep -A 10 CapAdd
```

### SOCKS5 не работает

```bash
# Проверьте что порт слушается
docker exec zapret2 netstat -tuln | grep 1080

# Проверьте redsocks
docker exec zapret2 ps aux | grep redsocks
```

### nfqws2 не запускается

```bash
# Проверьте процесс
docker exec zapret2 ps aux | grep nfqws2

# Проверьте NFQUEUE
docker exec zapret2 cat /proc/net/netfilter/nfnetlink_queue
```

## Лицензия

Следует лицензии основного проекта zapret2.

## Поддержка

Для вопросов и проблем создавайте issue в репозитории проекта.