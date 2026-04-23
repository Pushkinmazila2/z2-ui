# zapret2 Docker - Контейнеризация с SOCKS5 прокси

## Описание

Полностью изолированный Docker контейнер с zapret2 (nfqws2) и встроенным SOCKS5 прокси-сервером для обхода DPI (Deep Packet Inspection).

### Ключевые особенности

✅ **Полная изоляция** - весь трафик обрабатывается внутри контейнера, не затрагивая хост-систему

✅ **SOCKS5 прокси** - готовый к использованию прокси-сервер на порту 1080

✅ **Интеграция с singbox** - легко подключается к любым прокси-клиентам

✅ **Все стратегии zapret2** - поддержка всех lua-based стратегий обхода DPI

✅ **Минимальный размер** - образ на базе Alpine Linux (~100MB)

✅ **Гибкая настройка** - через переменные окружения или config файлы

## Архитектура

```
┌─────────────────────────────────────────────┐
│           zapret2 Container                 │
│                                             │
│  ┌──────────────────────────────────────┐  │
│  │  SOCKS5 Server (port 1080)           │  │
│  │  (redsocks)                          │  │
│  └────────────┬─────────────────────────┘  │
│               │                             │
│               ▼                             │
│  ┌──────────────────────────────────────┐  │
│  │  iptables/NFQUEUE                    │  │
│  │  (traffic redirection)               │  │
│  └────────────┬─────────────────────────┘  │
│               │                             │
│               ▼                             │
│  ┌──────────────────────────────────────┐  │
│  │  nfqws2 + lua scripts                │  │
│  │  (DPI bypass engine)                 │  │
│  └────────────┬─────────────────────────┘  │
│               │                             │
│               ▼                             │
│         Internet                            │
└─────────────────────────────────────────────┘
         ▲
         │ SOCKS5
         │
┌────────┴────────┐
│    singbox      │
│  or any client  │
└─────────────────┘
```

## Быстрый старт

### Вариант 1: Docker Compose (рекомендуется)

```bash
# Клонируйте репозиторий
git clone <repository-url>
cd zapret2

# Запустите
docker-compose up -d

# Проверьте
docker-compose logs -f zapret2
```

### Вариант 2: Docker CLI

```bash
# Соберите образ
docker build -t zapret2-proxy .

# Запустите контейнер
docker run -d \
  --name zapret2 \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --sysctl net.ipv4.ip_forward=1 \
  --sysctl net.ipv4.conf.all.route_localnet=1 \
  -p 1080:1080 \
  zapret2-proxy
```

### Проверка работы

```bash
# Тест SOCKS5
curl --socks5 localhost:1080 https://www.google.com

# Если видите HTML - всё работает!
```

## Документация

- **[QUICKSTART.md](docker/QUICKSTART.md)** - быстрый старт и примеры использования
- **[README.md](docker/README.md)** - полная документация по контейнеру
- **[config.example](docker/config.example)** - примеры конфигураций

## Требования

### Минимальные
- Docker 20.10+
- 512MB RAM
- Linux kernel с поддержкой netfilter_queue

### Рекомендуемые
- Docker 24.0+
- 1GB+ RAM
- Docker Compose 2.0+

## Конфигурация

### Переменные окружения

```yaml
environment:
  # SOCKS5 настройки
  - SOCKS5_PORT=1080              # Порт прокси
  - SOCKS5_USER=username          # Опционально: логин
  - SOCKS5_PASS=password          # Опционально: пароль
  
  # NFQUEUE настройки
  - NFQUEUE_NUM=200               # Номер очереди
  
  # zapret2 настройки
  - NFQWS2_ENABLE=1               # Включить nfqws2
  - DISABLE_IPV6=1                # Отключить IPv6
```

### Кастомная конфигурация

```bash
# 1. Создайте config
cp docker/config.example config

# 2. Отредактируйте NFQWS2_OPT
nano config

# 3. Примонтируйте в контейнер
volumes:
  - ./config:/opt/zapret2/config:ro
```

## Интеграция с singbox

### Docker Compose

```yaml
version: '3.8'

services:
  zapret2:
    build: .
    cap_add:
      - NET_ADMIN
      - NET_RAW
    sysctls:
      - net.ipv4.ip_forward=1
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
```

### Конфигурация singbox

```json
{
  "outbounds": [
    {
      "type": "socks",
      "tag": "zapret2",
      "server": "zapret2",
      "server_port": 1080
    }
  ]
}
```

## Примеры стратегий

### Базовая (HTTP + HTTPS)

```bash
NFQWS2_OPT="
--filter-tcp=80,443 --filter-l7=http,tls
--out-range=-d10
--payload=http_req --lua-desync=fake:blob=fake_default_http:tcp_md5
--payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:repeats=6 --lua-desync=multidisorder:pos=midsld
"
```

### Для YouTube

```bash
NFQWS2_OPT="
--filter-tcp=443 --filter-l7=tls --hostlist=/opt/zapret2/lists/youtube.txt
--out-range=-d10
--payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:repeats=11:tls_mod=rnd,dupsid,sni=www.google.com --lua-desync=multidisorder:pos=1,midsld
"
```

### С QUIC поддержкой

```bash
NFQWS2_OPT="
--filter-tcp=443 --filter-l7=tls
--payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5 --new
--filter-udp=443 --filter-l7=quic
--payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=11
"
```

## Отладка

```bash
# Логи контейнера
docker logs -f zapret2

# Проверка процессов
docker exec zapret2 ps aux

# Проверка iptables
docker exec zapret2 iptables -t nat -L -n -v
docker exec zapret2 iptables -t mangle -L -n -v

# Проверка SOCKS5
docker exec zapret2 netstat -tuln | grep 1080

# Debug режим
docker run -d \
  --name zapret2 \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --sysctl net.ipv4.ip_forward=1 \
  -p 1080:1080 \
  -e NFQWS2_OPT="--debug --filter-tcp=80,443 ..." \
  zapret2-proxy
```

## Структура проекта

```
zapret2/
├── Dockerfile              # Основной образ
├── docker-compose.yml      # Compose конфигурация
├── .dockerignore          # Исключения для сборки
├── DOCKER.md              # Эта документация
│
├── docker/
│   ├── entrypoint.sh      # Скрипт запуска
│   ├── redsocks.conf      # Конфиг redsocks
│   ├── queue.h            # Заголовок для Alpine
│   ├── config.example     # Пример конфигурации
│   ├── README.md          # Полная документация
│   └── QUICKSTART.md      # Быстрый старт
│
├── nfq2/                  # Исходники nfqws2
├── ip2net/                # Утилита ip2net
├── lua/                   # Lua скрипты
├── ipset/                 # IP списки
└── files/                 # Дополнительные файлы
```

## Безопасность

⚠️ **Важно:**

1. Контейнер требует привилегий `NET_ADMIN` и `NET_RAW`
2. Используйте аутентификацию SOCKS5 в продакшене
3. Ограничьте доступ к порту 1080 через firewall
4. Регулярно обновляйте образ

```yaml
# Пример с аутентификацией
environment:
  - SOCKS5_USER=myuser
  - SOCKS5_PASS=strongpassword123
```

## Производительность

- **RAM**: ~50-100MB в idle, до 200MB под нагрузкой
- **CPU**: зависит от объема трафика и сложности стратегий
- **Disk**: ~100MB образ

### Оптимизация

1. Используйте hostlist для ограничения обработки
2. Уменьшите `repeats` в стратегиях
3. Отключите IPv6 если не используется
4. Используйте простые стратегии где возможно

## Troubleshooting

### Контейнер не стартует

```bash
# Проверьте capabilities
docker inspect zapret2 | grep -A 10 CapAdd

# Проверьте sysctl
docker inspect zapret2 | grep -A 5 Sysctls
```

### SOCKS5 не работает

```bash
# Проверьте порт
docker exec zapret2 netstat -tuln | grep 1080

# Проверьте redsocks
docker exec zapret2 ps aux | grep redsocks

# Проверьте логи redsocks
docker logs zapret2 2>&1 | grep redsocks
```

### nfqws2 не запускается

```bash
# Проверьте процесс
docker exec zapret2 ps aux | grep nfqws2

# Проверьте NFQUEUE
docker exec zapret2 cat /proc/net/netfilter/nfnetlink_queue

# Проверьте lua скрипты
docker exec zapret2 ls -la /opt/zapret2/lua/
```

### Ошибка "Read-only file system"

Добавьте sysctl параметры:

```bash
docker run -d \
  --sysctl net.ipv4.ip_forward=1 \
  --sysctl net.ipv4.conf.all.route_localnet=1 \
  ...
```

## Ограничения

- ❌ Не работает в rootless режиме Docker
- ❌ Требуется Linux kernel с netfilter_queue
- ❌ Не поддерживается Windows containers
- ⚠️ Требует привилегированных capabilities

## Roadmap

- [ ] Поддержка автообновления hostlist'ов
- [ ] Web UI для управления
- [ ] Метрики и мониторинг (Prometheus)
- [ ] Поддержка нескольких профилей стратегий
- [ ] Helm chart для Kubernetes

## FAQ

**Q: Можно ли использовать без Docker Compose?**

A: Да, используйте `docker run` с необходимыми параметрами.

**Q: Как обновить стратегии без пересборки образа?**

A: Примонтируйте config файл через volume.

**Q: Работает ли с IPv6?**

A: Да, но по умолчанию отключено. Установите `DISABLE_IPV6=0`.

**Q: Можно ли использовать несколько контейнеров?**

A: Да, но нужно использовать разные порты для каждого.

**Q: Как добавить свои lua скрипты?**

A: Примонтируйте директорию с скриптами и укажите путь в `--lua-init`.

## Поддержка

- 📖 [Документация zapret2](docs/manual.md)
- 🐛 [Issues](https://github.com/your-repo/issues)
- 💬 [Discussions](https://github.com/your-repo/discussions)

## Лицензия

Следует лицензии основного проекта zapret2.

## Благодарности

- Автору zapret2 за отличный инструмент
- Сообществу за тестирование и обратную связь

---

**Создано с ❤️ для обхода цензуры**