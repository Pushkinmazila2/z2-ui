#!/bin/bash

# Скрипт для запуска blockcheck2 в отдельном контейнере
# Использование: ./blockcheck-runner.sh [домены]

set -e

DOMAINS="${1:-youtube.com}"
IMAGE_NAME="zapret2-proxy"

echo "=== Zapret2 BlockCheck Runner ==="
echo "Домены для проверки: $DOMAINS"
echo

# Проверяем наличие образа
if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    echo "Образ $IMAGE_NAME не найден. Собираем..."
    docker-compose build
fi

# Останавливаем работающий контейнер если есть
if docker ps -a --format '{{.Names}}' | grep -q '^zapret2-proxy$'; then
    echo "Останавливаем работающий контейнер zapret2-proxy..."
    docker-compose down
fi

echo "Запускаем blockcheck2 в тестовом контейнере..."
echo

# Запускаем временный контейнер для тестирования
docker run -it --rm \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --sysctl net.ipv4.ip_forward=1 \
  --sysctl net.ipv4.conf.all.route_localnet=1 \
  --name zapret2-blockcheck \
  "$IMAGE_NAME" \
  bash -c "
    export SKIP_DNSCHECK=1
    export SECURE_DNS=0
    export IPVS=4
    export ENABLE_HTTP=0
    export ENABLE_HTTPS_TLS12=1
    export ENABLE_HTTPS_TLS13=1
    export ENABLE_HTTP3=0
    export REPEATS=2
    export PARALLEL=1
    export SCANLEVEL=standard
    export BATCH=1
    export DOMAINS='$DOMAINS'
    
    echo '* Запуск blockcheck2 с прогресс-баром...'
    /opt/zapret2/blockcheck2-progress.sh
    
    echo
    echo '=== Тест завершен ==='
    echo 'Скопируйте найденную стратегию в config файл'
    echo 'и перезапустите контейнер: docker-compose up -d'
  "

echo
echo "=== Готово ==="
echo "Для применения найденной стратегии:"
echo "1. Создайте/отредактируйте файл 'config'"
echo "2. Добавьте найденные параметры в NFQWS2_OPT"
echo "3. Запустите: docker-compose up -d"