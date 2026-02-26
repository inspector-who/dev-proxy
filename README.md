# dev-proxy (общий Traefik для локальной разработки)

Поднимает единый Traefik для всех ваших локальных проектов.
Проекты подключаются к внешней сети и объявляют роуты через Docker labels — собственный Traefик в каждом проекте не нужен.

## Что внутри
- `docker-compose.yml` — Traefik v3.6, публикация портов 80/443/8081 (значения можно переопределить через `.env`: `TRAEFIK_PORT_HTTP`, `TRAEFIK_PORT_HTTPS`, `TRAEFIK_PORT_DASHBOARD`).
- `gateway/dynamic/` — каталог для динамических файловых правил (опционально, можно оставить пустым).
- `gateway/certs/` — каталог для dev‑сертификатов (опционально).

Сеть `traefik` внешняя (external) и общая. Имя сети берётся из переменной `TRAEFIK_NETWORK` (по умолчанию `traefik`).

## Быстрый старт
1) Подготовьте `.env` (создастся из `.env.dist`, если ещё не существует):
```bash
make init
```
2) Создайте сеть (если её нет) и поднимите общий Traefik из корня репозитория:
```bash
./scripts/dev-proxy.sh up
```
Проверка:
- Откройте Traefik dashboard: по умолчанию `http://localhost:8081`. Если меняли порт — используйте значение из `.env` (`TRAEFIK_PORT_DASHBOARD`).

Альтернатива: руками через Docker
```bash
docker network create traefik || true
docker compose -p dev-proxy up -d
```

## Порты
Порты на хосте можно задавать в `.env` (дефолты в скобках):
- `TRAEFIK_PORT_HTTP` (80)
- `TRAEFIK_PORT_HTTPS` (443)
- `TRAEFIK_PORT_DASHBOARD` (8081)
Скрипт `dev-proxy.sh up` печатает подсказку с фактическими значениями.

## Управление сертификатами (SAN)
Рекомендуется использовать встроенные команды на базе `mkcert` (при его отсутствии используется `openssl`, будет самоподписанный сертификат):
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
- Сертификаты лежат в `gateway/certs/`: `dev.pem` (сертификат) и `dev-key.pem` (ключ). ЭТИХ ДВУХ ФАЙЛОВ ДОСТАТОЧНО для всех доменов — все имена попадают в SAN одного сертификата, отдельные файлы под каждый домен не нужны.
- `add` — объединяет существующие SAN с новыми именами и перевыпускает сертификат (бэкапится и cert, и key в `gateway/certs/backups/` с меткой времени: `dev.pem.YYYYMMDD-HHMMSS.BAK`, `dev-key.pem.YYYYMMDD-HHMMSS.BAK`).
- `rm` — удаляет указанные SAN. Невозможно оставить пустой список SAN — команда остановится с ошибкой.
- `ls` — показывает все имена из SAN. Если имя указано только как CN, оно тоже будет отображено.

Установка mkcert: https://github.com/FiloSottile/mkcert

## Утилита scripts/dev-proxy.sh
Команды:
```bash
./scripts/dev-proxy.sh up                 # создать сеть (если нет) и поднять Traefik
./scripts/dev-proxy.sh down               # остановить Traefik
./scripts/dev-proxy.sh logs               # логи Traefik
./scripts/dev-proxy.sh status             # статус
./scripts/dev-proxy.sh restart            # перезапуск
./scripts/dev-proxy.sh network            # только создать/проверить внешнюю сеть
./scripts/dev-proxy.sh config             # docker compose config

# Управление dev-сертификатами (SAN):
./scripts/dev-proxy.sh mkcert ls          # показать SAN
./scripts/dev-proxy.sh mkcert add HOST..  # добавить SAN и перевыпустить (с бэкапом)
./scripts/dev-proxy.sh mkcert rm HOST..   # удалить SAN и перевыпустить (с бэкапом)
./scripts/dev-proxy.sh mkcert backup      # сделать бэкап dev.pem/dev-key.pem
```
Скрипт читает `.env` и использует `TRAEFIK_NETWORK` (по умолчанию `traefik`). Порты берутся из `.env` (см. выше).

### Установка в PATH (команда `dev-proxy`)
Чтобы запускать просто `dev-proxy up/down/...`, установите симлинк в `/usr/local/bin`:
```bash
sudo ln -sf "$(pwd)/scripts/dev-proxy.sh" /usr/local/bin/dev-proxy
# Проверка
dev-proxy config >/dev/null && echo "dev-proxy OK"
```
Симлинк позволяет корректно определить корень репозитория. Если вы скопировали файл, задайте `DEV_PROXY_ROOT` в окружении или используйте обёртку.

Удаление симлинка:
```bash
sudo rm -f /usr/local/bin/dev-proxy
```

## VPN, маршруты и выбор подсети (CIDR)
При активном VPN часто появляются маршруты вида `10.0.0.0/8`, `172.16.0.0/12` и пр. Если Docker попытается создать сеть с пересечением, вы можете увидеть ошибку:
```
Error response from daemon: all predefined address pools have been fully subnetted
```
или контейнеры не будут резолвиться друг к другу. Рекомендации:

1) Посмотреть активные маршруты и существующие сети:
```bash
ip -4 route
docker network ls
# для конкретной сети: docker network inspect <name> | grep Subnet
```
2) Выбрать свободный CIDR, не пересекающийся с локальной сетью и маршрутами VPN. Часто подойдут: `172.30.0.0/16`, `172.31.0.0/16`, `10.123.0.0/16`, `192.168.100.0/24` — но проверяйте у себя.
3) Явно создать сеть с этим CIDR (с VPN можно и без него — главное, чтобы не было пересечения):
```bash
TRAEFIK_SUBNET=10.123.0.0/16 ./scripts/dev-proxy.sh network
# или вручную: docker network create --subnet 10.123.0.0/16 traefik
```
Скрипт при создании сети сначала пробует дефолт, затем перебирает кандидатов из `TRAEFIK_SUBNETS`/`TRAEFIK_SUBNET`/дефолтного набора.

Если сеть уже создана неудачно, её можно удалить (если она не используется) и создать заново с нужным CIDR:
```bash
docker network rm traefik
TRAEFIK_SUBNET=10.123.0.0/16 ./scripts/dev-proxy.sh network
```

## Автозапуск при старте Docker / системы
В `docker-compose.yml` задано `restart: unless-stopped` — это означает, что если контейнеры уже созданы и были запущены, они автоматически поднимутся после перезапуска Docker (и системы). Достаточно один раз выполнить `./scripts/dev-proxy.sh up`.

Если хотите гарантировать подъём даже после полной очистки/обновления (или запускать `up` при входе пользователя), можно добавить user systemd unit:
```ini
# ~/.config/systemd/user/dev-proxy.service
[Unit]
Description=Dev Traefik proxy
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=DEV_PROXY_ROOT=%h/dev/services/dev-proxy
ExecStart=%h/dev/services/dev-proxy/scripts/dev-proxy.sh up
ExecStop=%h/dev/services/dev-proxy/scripts/dev-proxy.sh down

[Install]
WantedBy=default.target
```
Активация:
```bash
systemctl --user daemon-reload
systemctl --user enable --now dev-proxy.service
```
Для глобальной службы используйте `/etc/systemd/system` и `sudo`, поправив пути.

## Makefile: инициализация
Цель `make init` создаёт `.env` из `.env.dist`, только если `.env` ещё не существует — ваши локальные переопределения не перезатираются.

## Траблшутинг
- Порты заняты — переопределите их в `.env` (`TRAEFIK_PORT_HTTP`, `TRAEFIK_PORT_HTTPS`, `TRAEFIK_PORT_DASHBOARD`).
- Резолвинг доменов — пропишите их в `/etc/hosts`.
- Ошибки с сетью / CIDR — смотрите раздел про VPN и явный выбор подсети.
