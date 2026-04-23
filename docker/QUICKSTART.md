# Быстрый старт zapret2 Docker

## 1. Сборка и запуск (5 минут)

```bash
# Клонируйте репозиторий (если еще не сделали)
git clone <repository-url>
cd zapret2

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

# Проверьте логи
docker logs -f zapret2
```

## 2. Проверка работы

```bash
# Тест SOCKS5 прокси
curl --socks5 localhost:1080 https://www.google.com

# Если работает - увидите HTML страницу Google
```

## 3. Подключение singbox

### Вариант A: Docker Compose (рекомендуется)

```bash
# Используйте готовый docker-compose.yml
docker-compose up -d

# Проверьте статус
docker-compose ps
```

### Вариант B: Ручная настройка singbox

В конфигурации singbox добавьте outbound:

```json
{
  "outbounds": [
    {
      "type": "socks",
      "tag": "zapret2",
      "server": "localhost",
      "server_port": 1080
    }
  ]
}
```

Если singbox в другом контейнере:
- Используйте имя контейнера вместо `localhost`
- Или IP адрес контейнера zapret2

## 4. Настройка стратегий DPI

### Базовая конфигурация (работает из коробки)

По умолчанию включена базовая стратегия для HTTP/HTTPS.

### Кастомная конфигурация

```bash
# 1. Создайте config файл
cp docker/config.example config

# 2. Отредактируйте NFQWS2_OPT в config
nano config

# 3. Перезапустите с новым конфигом
docker run -d \
  --name zapret2 \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --sysctl net.ipv4.ip_forward=1 \
  --sysctl net.ipv4.conf.all.route_localnet=1 \
  -p 1080:1080 \
  -v $(pwd)/config:/opt/zapret2/config:ro \
  zapret2-proxy
```

### Примеры стратегий

#### Для YouTube

```bash
NFQWS2_OPT="
--filter-tcp=443 --filter-l7=tls
--out-range=-d10
--payload=tls_client_hello 
--lua-desync=fake:blob=fake_default_tls:tcp_md5:repeats=11:tls_mod=rnd,dupsid,sni=www.google.com 
--lua-desync=multidisorder:pos=1,midsld
"
```

#### Для Discord

```bash
NFQWS2_OPT="
--filter-tcp=443 --filter-l7=tls
--out-range=-d10
--payload=tls_client_hello 
--lua-desync=fake:blob=fake_default_tls:tcp_md5:repeats=6 
--lua-desync=multisplit:pos=midsld
"
```

## 5. Использование hostlist'ов

```bash
# 1. Создайте директорию для списков
mkdir -p lists

# 2. Добавьте домены
echo "youtube.com" > lists/youtube.txt
echo "googlevideo.com" >> lists/youtube.txt

# 3. Запустите с hostlist
docker run -d \
  --name zapret2 \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --sysctl net.ipv4.ip_forward=1 \
  --sysctl net.ipv4.conf.all.route_localnet=1 \
  -p 1080:1080 \
  -v $(pwd)/lists:/opt/zapret2/lists:ro \
  -e NFQWS2_OPT="--filter-tcp=443 --hostlist=/opt/zapret2/lists/youtube.txt --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5" \
  zapret2-proxy
```

## 6. Отладка

```bash
# Логи контейнера
docker logs -f zapret2

# Проверка процессов
docker exec zapret2 ps aux

# Проверка iptables
docker exec zapret2 iptables -t nat -L -n -v
docker exec zapret2 iptables -t mangle -L -n -v

# Проверка SOCKS5 порта
docker exec zapret2 netstat -tuln | grep 1080

# Включить debug режим
docker run -d \
  --name zapret2 \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --sysctl net.ipv4.ip_forward=1 \
  --sysctl net.ipv4.conf.all.route_localnet=1 \
  -p 1080:1080 \
  -e NFQWS2_OPT="--debug --filter-tcp=80,443 --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5" \
  zapret2-proxy
```

## 7. Остановка и удаление

```bash
# Остановить
docker stop zapret2

# Удалить
docker rm zapret2

# Удалить образ
docker rmi zapret2-proxy
```

## Частые проблемы

### Контейнер не запускается

**Проблема**: `Error response from daemon: linux runtime spec devices: error gathering device information while adding custom device`

**Решение**: Убедитесь что у Docker есть права на NET_ADMIN:
```bash
docker run --cap-add NET_ADMIN --cap-add NET_RAW ...
```

### SOCKS5 не отвечает

**Проблема**: `curl: (7) Failed to connect to localhost port 1080`

**Решение**: 
1. Проверьте что контейнер запущен: `docker ps`
2. Проверьте логи: `docker logs zapret2`
3. Проверьте порт: `docker exec zapret2 netstat -tuln | grep 1080`

### nfqws2 не работает

**Проблема**: В логах ошибки от nfqws2

**Решение**:
1. Проверьте синтаксис NFQWS2_OPT
2. Включите debug: добавьте `--debug` в начало NFQWS2_OPT
3. Проверьте что lua скрипты на месте: `docker exec zapret2 ls -la /opt/zapret2/lua/`

### Медленная работа

**Проблема**: Трафик идет медленно через прокси

**Решение**:
1. Уменьшите количество repeats в стратегии
2. Используйте более простые стратегии
3. Ограничьте обработку только нужными портами/доменами через hostlist

## Полезные команды

```bash
# Перезапустить контейнер
docker restart zapret2

# Посмотреть использование ресурсов
docker stats zapret2

# Зайти в контейнер
docker exec -it zapret2 /bin/bash

# Обновить образ
docker pull zapret2-proxy:latest
docker stop zapret2
docker rm zapret2
docker run -d ... zapret2-proxy:latest
```

## Следующие шаги

1. Прочитайте полную документацию: `docker/README.md`
2. Изучите примеры конфигураций: `docker/config.example`
3. Настройте автозапуск через systemd или docker-compose
4. Добавьте мониторинг и алерты

## Поддержка

Если возникли проблемы:
1. Проверьте логи: `docker logs zapret2`
2. Изучите документацию zapret2: `docs/manual.md`
3. Создайте issue в репозитории проекта