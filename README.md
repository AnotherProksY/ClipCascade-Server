# ClipCascade-Server

Серверная часть общего буфера обмена между Android и Linux: [ClipCascade](https://github.com/Sathvik-Rao/ClipCascade) на `headscale-ru` (Ubuntu 24.04), снаружи — `https://clip.kfazilov.online`.

Здесь лежат конфиги в том виде, в каком они стоят на сервере, и инструкция, как всё поднять заново руками. Клиент на ноутбуке (сервис `clipcascade.service`, скрипт `68-clipcascade`) живёт в dotfiles.

## Как устроено

```
телефон / ноутбук ──https──▶ Caddy :443 ─┬─ clip.kfazilov.online      → 127.0.0.1:8081 (Docker, ClipCascade)
                                         └─ headscale.kfazilov.online → 127.0.0.1:8080 (headscale)
```

- **Caddy** держит 80/443 и сам получает сертификаты Let's Encrypt для обоих доменов. Раньше 80/443 занимал сам headscale со встроенным Let's Encrypt. Теперь он слушает только `127.0.0.1:8080`, без TLS. Встроенный DERP в headscale выключен, поэтому `/derp` отдаёт 404, это нормально.
- **ClipCascade** в Docker, `/opt/clipcascade`: режим через сервер (не P2P), лимит сообщения 25 MiB, регистрация выключена. База H2 зашифрована и лежит в `/opt/clipcascade/cc_users`.

## Файлы

| Файл | Куда на сервере |
|---|---|
| `docker-compose.yml` | `/opt/clipcascade/docker-compose.yml` |
| `.env` (не в git) | `/opt/clipcascade/.env`, `chmod 600` |
| `Caddyfile` | `/etc/caddy/Caddyfile` |
| `headscale-behind-caddy.patch` | что поменяно в `/etc/headscale/config.yaml` |

**`.env` — единственный секрет.** `CC_SERVER_DB_PASSWORD` — два пароля через пробел: шифрование файла H2 и пользователь БД. Без пробела контейнер падает с `Wrong password format`. С другим паролем существующая база не откроется, поэтому `.env` нужно хранить: копия есть здесь и на сервере. Для новой базы пароль генерируется так:

```sh
echo "CC_SERVER_DB_PASSWORD=\"$(openssl rand -hex 24) $(openssl rand -hex 24)\"" > .env
```

## Развернуть с нуля

1. **DNS** (Porkbun): A-запись `clip.kfazilov.online → <IP сервера>`. Без неё домен попадает под wildcard `*.kfazilov.online`, который ведёт на парковку Porkbun, и Caddy не получит сертификат. Проверка: `dig +short clip.kfazilov.online`.

2. **Пакеты:**
   ```sh
   sudo apt-get install -y docker.io docker-compose-v2 caddy
   sudo systemctl stop caddy    # пока 80/443 занят headscale
   ```

3. **ClipCascade** (скопировать `docker-compose.yml` и `.env` на сервер, например через `scp` в домашнюю папку):
   ```sh
   sudo install -Dm644 docker-compose.yml /opt/clipcascade/docker-compose.yml
   sudo install -Dm600 .env /opt/clipcascade/.env
   cd /opt/clipcascade && sudo docker compose up -d
   curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8081/login   # 200 через ~20 с
   ```
   При переносе на другой сервер вместе с `.env` скопировать и `/opt/clipcascade/cc_users`, иначе пользователей придётся создавать заново.

4. **headscale за Caddy**: в `/etc/headscale/config.yaml` поменять две строки, как в `headscale-behind-caddy.patch`:
   ```yaml
   listen_addr: 127.0.0.1:8080
   tls_letsencrypt_hostname: ""
   ```
   ```sh
   sudo cp -a /etc/headscale/config.yaml /etc/headscale/config.yaml.bak-pre-caddy
   # правка
   sudo headscale configtest
   ```

5. **Caddy** (скопировать `Caddyfile`), затем переключить порты. headscale недоступен на несколько секунд, SSH не затрагивается:
   ```sh
   caddy validate --config Caddyfile --adapter caddyfile
   sudo install -m644 Caddyfile /etc/caddy/Caddyfile
   sudo systemctl restart headscale
   sudo systemctl enable --now caddy
   ```

6. **Проверка** (с любой машины):
   ```sh
   curl -s -o /dev/null -w '%{http_code}\n' https://clip.kfazilov.online/login        # 200
   curl -s -o /dev/null -w '%{http_code}\n' https://headscale.kfazilov.online/health  # 200
   ```
   И что узлы tailnet переподключились: `sudo headscale nodes list` на сервере.

7. **Админка**: `https://clip.kfazilov.online`, вход под стандартным админом из README ClipCascade. Сразу сменить пароль и создать пользователя для устройств.

**Откат headscale**: `sudo systemctl disable --now caddy`, вернуть бэкап `config.yaml.bak-pre-caddy`, `sudo systemctl restart headscale`.

## Обновить

ClipCascade: поменять тег образа в `docker-compose.yml` (здесь и на сервере), затем
```sh
cd /opt/clipcascade && sudo docker compose pull && sudo docker compose up -d
```
Поменять Caddyfile: `sudo systemctl reload caddy` после замены файла.

## Почему так

- **`SERVER_SERVLET_SESSION_PERSISTENT`**: ClipCascade держит сессии в памяти, и любой рестарт контейнера разлогинивал все клиенты. Клиент на Linux сам заново не входит, а бесконечно стучится со старой cookie (`Invalid redirect target .../login`). Теперь Tomcat при остановке сохраняет сессии в `cc_users/sessions/SESSIONS.ser`. Это работает только при штатной остановке (`docker compose restart/down`, перезагрузка сервера). После `kill -9` или падения войти придётся заново.
- **`SERVER_FORWARD_HEADERS_STRATEGY=native`**: без этого Spring не видит `X-Forwarded-Proto` от Caddy и редиректит на `http://`.
- **Образ `0.7.0`, а не `latest`**: у сервера своя нумерация версий, клиенты 3.x с ним совместимы. `latest` при `pull` обновил бы сервер незаметно.
- **Порт `127.0.0.1:8081`**: снаружи ClipCascade доступен только через Caddy с TLS.
