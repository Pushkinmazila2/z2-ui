# Zapret2 Web Control Panel

Легковесная веб-панель для быстрой смены стратегий обхода DPI.

## Возможности

- 🎯 Быстрое переключение между предустановленными стратегиями
- 🔐 Защита логином/паролем (HTTP Basic Auth)
- 📦 Минимальный вес (чистый Python, без зависимостей)
- 🐳 Полная интеграция с Docker
- 🎨 Современный темный интерфейс

## Быстрый старт

### Docker (рекомендуется)

1. Запустите контейнер:
```bash
docker-compose up -d
```

2. Откройте веб-панель:
```
http://localhost:8088
```

3. Войдите с дефолтными учетными данными:
- **Логин:** admin
- **Пароль:** zapret

### Смена пароля

Внутри контейнера:
```bash
docker exec -it zapret2-proxy python3 /opt/zapret2/web/change_password.py
```

Или вручную отредактируйте файл `.htpasswd`:
```bash
docker exec -it zapret2-proxy vi /opt/zapret2/web/.htpasswd
```

Формат: `username:sha256_hash`

## Использование

1. Откройте веб-панель в браузере
2. Выберите нужную стратегию из списка
3. Нажмите "Применить стратегию"
4. Перезапустите контейнер для применения изменений:
   ```bash
   docker restart zapret2-proxy
   ```

## Предустановленные стратегии

### YouTube Aggressive
Агрессивная стратегия для YouTube и Google сервисов с множественными fake пакетами и модификацией TLS.

### Simple Fake
Простая стратегия с базовыми fake пакетами, подходит для большинства случаев.

### Multisplit
Стратегия с разделением пакетов, эффективна против простых DPI систем.

## Добавление своих стратегий

Отредактируйте файл `strategies.json`:

```json
{
  "my_strategy": {
    "name": "Моя стратегия",
    "description": "Описание стратегии",
    "config": "--filter-tcp=443 --lua-desync=fake..."
  }
}
```

## Настройка порта

В `docker-compose.yml` или `.env`:
```yaml
WEB_PORT=8088
```

## Безопасность

⚠️ **ВАЖНО:** Смените дефолтный пароль после первого запуска!

- Веб-панель использует HTTP Basic Auth
- Пароли хранятся в виде SHA256 хешей
- Рекомендуется использовать за reverse proxy с HTTPS
- Ограничьте доступ через firewall

## Архитектура

```
┌─────────────┐
│   Browser   │
└──────┬──────┘
       │ HTTP :8088
       ▼
┌─────────────┐
│  Web Panel  │ (Python)
└──────┬──────┘
       │
       ├─► config (read/write)
       └─► Docker restart (manual)
```

## Troubleshooting

### Веб-панель не открывается
```bash
# Проверьте логи
docker logs zapret2-proxy | grep "Web Control Panel"

# Проверьте порт
docker ps | grep 8088
```

### Стратегия не применяется
```bash
# Проверьте config файл
docker exec zapret2-proxy cat /opt/zapret2/config

# Перезапустите контейнер
docker restart zapret2-proxy
```

### Забыли пароль
```bash
# Удалите файл паролей (вернется дефолтный)
docker exec zapret2-proxy rm /opt/zapret2/web/.htpasswd
docker restart zapret2-proxy
```

## Технические детали

- **Язык:** Python 3 (stdlib only)
- **Вес:** ~15KB (server.py)
- **Зависимости:** Нет (только stdlib)
- **Порт по умолчанию:** 8088
- **Аутентификация:** HTTP Basic Auth + SHA256

## Лицензия

Часть проекта zapret2