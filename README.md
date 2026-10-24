# ClipCascade-Server

Серверная часть общего буфера обмена между Android и Linux: [ClipCascade](https://github.com/Sathvik-Rao/ClipCascade) на `headscale-ru` (Ubuntu 24.04), снаружи — `https://clip.kfazilov.online`.

Клиент на ноутбуке (сервис `clipcascade.service`, скрипт `68-clipcascade`) живёт в dotfiles, здесь — только сервер.

## Как устроено

```
телефон / ноутбук ──https──▶ Caddy :443 ─┬─ clip.kfazilov.online      → 127.0.0.1:8081 (Docker, ClipCascade)
                                         └─ headscale.kfazilov.online → 127.0.0.1:8080 (headscale)
```

- **Caddy** держит 80/443 и сам получает сертификаты Let's Encrypt для обоих доменов. Раньше 80/443 занимал сам headscale со встроенным Let's Encrypt; теперь он слушает только `127.0.0.1:8080`, без TLS (`headscale-behind-caddy.patch`, бэкап на сервере: `/etc/headscale/config.yaml.bak-pre-caddy`). Встроенный DERP в headscale выключен, поэтому `/derp` отдаёт 404 — это нормально.
- **ClipCascade** в Docker, `/opt/clipcascade`: режим через сервер (не P2P), лимит сообщения 25 MiB, регистрация выключена. База H2 зашифрована, лежит в `/opt/clipcascade/cc_users`.
- DNS: A-запись `clip.kfazilov.online → 185.149.147.254` в Porkbun (wildcard `*.kfazilov.online` уходит на парковку Porkbun).

## Файлы

| Файл | Куда на сервере |
|---|---|
| `docker-compose.yml` | `/opt/clipcascade/docker-compose.yml` |
| `.env` (не в git, `chmod 600`) | `/opt/clipcascade/.env` |
| `Caddyfile` | `/etc/caddy/Caddyfile` |
| `headscale-behind-caddy.patch` | справка: что поменяно в `/etc/headscale/config.yaml` |

## Деплой

```sh
./deploy.sh            # или ./deploy.sh <ssh-host>
```

Копирует файлы, проверяет Caddyfile, делает `systemctl reload caddy` и `docker compose up -d`, затем проверяет оба домена.

**Пароль БД не менять.** `CC_SERVER_DB_PASSWORD` — два пароля через пробел: шифрование файла H2 и пользователь БД. Без пробела контейнер падает с `Wrong password format`. С другим паролем существующая база не откроется. Копия `.env` есть только здесь и на сервере.

## Почему так

- **`SERVER_SERVLET_SESSION_PERSISTENT`**: ClipCascade держит сессии в памяти, и любой рестарт контейнера разлогинивал все клиенты. Клиент на Linux сам заново не входит, а бесконечно стучится со старой cookie (`Invalid redirect target .../login`). Теперь Tomcat при остановке сохраняет сессии в `cc_users/sessions/SESSIONS.ser`. Работает только при штатной остановке (`docker compose restart/down`), после `kill -9` или падения сервера войти придётся заново.
- **`SERVER_FORWARD_HEADERS_STRATEGY=native`**: без этого Spring не видит `X-Forwarded-Proto` от Caddy и редиректит на `http://`.
- **Образ `0.7.0`, а не `latest`**: у сервера своя нумерация версий, клиенты 3.x с ним совместимы. Обновление — поменять тег и `./deploy.sh`.

## Админка

`https://clip.kfazilov.online` → вход под админом. Пользователи создаются там же, регистрация закрыта.
