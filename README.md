# dev-proxy (общий Traefik для локальной разработки)

Поднимает единый Traefik для всех ваших локальных проектов. 
Проекты подключаются к внешней сети и объявляют роуты через Docker labels — собственный Traефик в каждом проекте не нужен.

## Что внутри
- `docker-compose.yml` — Traefik v2.11, публикация портов 80/443/8081 (значения можно переопределить через `.env`: `TRAEFIK_PORT_HTTP`, `TRAEFIK_PORT_HTTPS`, `TRAEFIK_PORT_DASHBOARD`).
- `gateway/dynamic/` — каталог для динамических файловых правил (опционально, можно оставить пустым).
- `gateway/certs/` — каталог для dev‑сертификатов (опционально).

Сеть `traefik` внешняя (external) и общая. Имя сети берётся из переменной `TRAEFIK_NETWORK` (по умолчанию `traefik`).

## Быстрый старт
1) Создайте сеть (один раз):
```bash
docker network create traefik || true
```
2) Поднимите общий Traefik (в корне репозитория):
```bash
docker compose -p dev-proxy -f dev-proxy/docker-compose.yml up -d
```
Или с помощью утилиты:
```bash
./scripts/dev-proxy.sh up
```
3) В проектах используйте внешнюю сеть:
- В `.env`: `TRAEFIK_NETWORK=traefik` (дефолт).
- В `docker-compose.yml`: сеть `traefik` объявлена как `external: true`, `name: ${TRAEFIK_NETWORK}`.
- Запуск проекта: `make docker-up` или `make init`.

Проверка:
- Откройте Traefik dashboard: по умолчанию `http://localhost:8081`. Если меняли порт — используйте значение из `.env` (`TRAEFIK_PORT_DASHBOARD`).

## Сертификаты (опционально)

> Установка mkcert (смотри инструкции для нужной ОС)
> https://github.com/FiloSottile/mkcert

Рекомендуется использовать встроенное управление сертификатами:
```bash
# список доменов (SAN) в текущем сертификате
./scripts/dev-proxy.sh mkcert ls

# добавить SAN-домены (перед изменением создаются бэкапы)
./scripts/dev-proxy.sh mkcert add domain1.local sub.domain2.local

# удалить SAN-домены (перед изменением создаются бэкапы)
./scripts/dev-proxy.sh mkcert rm domain1.local

# создать бэкап текущих dev.pem/dev-key.pem
./scripts/dev-proxy.sh mkcert backup
```
Как это работает:
- Сертификаты лежат в `gateway/certs/`: `dev.pem` (сертификат) и `dev-key.pem` (ключ). Эти два файла покрывают все указанные домены через SAN — отдельные файлы под каждый домен не нужны.
- При `add` существующие SAN сохраняются, добавляются новые и сертификат перевыпускается (через `mkcert`, при его отсутствии — через `openssl`).
- При `rm` удаляются указанные SAN; нельзя оставить пустой список SAN — операция остановится с ошибкой.
- Перед любыми изменениями создаётся бэкап обоих файлов в `gateway/certs/backups/` с меткой времени: `dev.pem.YYYYMMDD-HHMMSS.BAK` и `dev-key.pem.YYYYMMDD-HHMMSS.BAK`.
- Если `mkcert` не установлен, будет выпущен самоподписанный сертификат (браузер предупредит о небезопасности).

Ручная альтернатива (необязательно):
```bash
mkcert -install
mkcert -cert-file dev-proxy/gateway/certs/dev.pem -key-file dev-proxy/gateway/certs/dev-key.pem \
  domain1.local domain2.local subdomain.domain2.local
```
Или через openssl (самоподписанный):
```bash
openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
  -keyout dev-proxy/gateway/certs/dev-key.pem \
  -out dev-proxy/gateway/certs/dev.pem \
  -subj "/CN=domain.local" \
  -addext "subjectAltName=DNS:domain.local,DNS:subdomain.domain.local,DNS:example.local"
```

## Утилита scripts/dev-proxy.sh
В корне репозитория есть скрипт для управления общим Traefik:
```bash
./scripts/dev-proxy.sh up                 # создать сеть (если нет) и поднять Traefik
./scripts/dev-proxy.sh down               # остановить Traefik
./scripts/dev-proxy.sh logs               # логи Traefik
./scripts/dev-proxy.sh status             # статус
./scripts/dev-proxy.sh restart            # перезапуск
./scripts/dev-proxy.sh network            # только создать/убедиться, что есть внешняя сеть
./scripts/dev-proxy.sh config             # docker compose config

# Управление dev-сертификатами (SAN):
./scripts/dev-proxy.sh mkcert ls          # показать SAN
./scripts/dev-proxy.sh mkcert add HOST..  # добавить SAN и перевыпустить (с бэкапом)
./scripts/dev-proxy.sh mkcert rm HOST..   # удалить SAN и перевыпустить (с бэкапом)
./scripts/dev-proxy.sh mkcert backup      # сделать бэкап dev.pem/dev-key.pem
```
Скрипт читает `.env` из корня (если есть) и использует `TRAEFIK_NETWORK` (по умолчанию `traefik`). Порты на хосте можно переопределять через `.env`: `TRAEFIK_PORT_HTTP` (дефолт 80), `TRAEFIK_PORT_HTTPS` (дефолт 443), `TRAEFIK_PORT_DASHBOARD` (дефолт 8081). При запуске `up` скрипт выводит подсказку с фактическими портами из `.env`.

### Установка в PATH (macOS/Linux) — команда `dev-proxy`
Чтобы запускать просто `dev-proxy up/down/...`, установите симлинк в `/usr/local/bin`.

Вариант A (рекомендуется): симлинк — работает из любого каталога без доп. настроек
```bash
# Выполнить из корня репозитория
sudo ln -sf "$(pwd)/scripts/dev-proxy.sh" /usr/local/bin/dev-proxy
# Проверка
dev-proxy config >/dev/null && echo "dev-proxy OK"
```
Симлинк позволяет скрипту определить корень репозитория автоматически (через readlink/realpath) и корректно найти `dev-proxy/docker-compose.yml`.

Вариант B: копия + указать корень (DEV_PROXY_ROOT)
```bash
# Выполнить из корня репозитория
sudo install -m755 scripts/dev-proxy.sh /usr/local/bin/dev-proxy
# Указать путь до корня (один раз), чтобы скрипт знал, где лежит dev-proxy/
# Добавьте в ~/.bashrc или ~/.zshrc:
#   export DEV_PROXY_ROOT="/абсолютный/путь/до/репозитория"
# Или создайте обёртку:
cat <<'EOF' | sudo tee /usr/local/bin/dev-proxy >/dev/null
#!/usr/bin/env bash
export DEV_PROXY_ROOT="/абсолютный/путь/до/репозитория"
exec "$DEV_PROXY_ROOT/scripts/dev-proxy.sh" "$@"
EOF
sudo chmod +x /usr/local/bin/dev-proxy
```
Если вы просто скопируете файл без симлинка и без `DEV_PROXY_ROOT`, скрипт сможет работать только при запуске из корня репозитория (он попробует найти `dev-proxy/` относительно текущего каталога).

Удаление:
```bash
sudo rm -f /usr/local/bin/dev-proxy
```

## Makefile: инициализация
Цель `make init` создаст `.env` из `.env.dist`, только если `.env` ещё не существует. Это безопасно для ваших локальных переопределений.

## Примечания и траблшутинг
- Порты 80/443/8081 публикуются на хост; если они заняты, переопределите через `.env` (`TRAEFIK_PORT_HTTP`, `TRAEFIK_PORT_HTTPS`, `TRAEFIK_PORT_DASHBOARD`).
- Убедитесь, что домены проектов не конфликтуют и прописаны в `/etc/hosts`.
- Внешняя сеть `traefik` не удаляется при `docker compose down` в проектах.
- Ошибка при создании сети: `all predefined address pools have been fully subnetted`. Решения:
  - Запустите `make networks-prune` и повторите.
  - Явно задайте свободную подсеть при создании сети, например:
    ```bash
    TRAEFIK_SUBNET=10.123.0.0/16 make init-network
    ```
  - Или создайте сеть вручную: `docker network create --subnet 10.123.0.0/16 traefik`.
