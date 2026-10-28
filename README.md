# ClipCascade-Server

Серверная часть общего буфера обмена между Android и Linux: [ClipCascade](https://github.com/Sathvik-Rao/ClipCascade) на `headscale-ru` (Ubuntu 24.04), снаружи — `https://clip.kfazilov.online`.

Здесь лежат конфиги в том виде, в каком они стоят на сервере, и инструкция, как всё поднять заново руками. Клиент на ноутбуке (сервис `clipcascade.service`, скрипт `68-clipcascade`) живёт в dotfiles.

## Как устроено

```
телефон / ноутбук ──https──▶ Caddy :443 ─┬─ clip.kfazilov.online      → 127.0.0.1:8081 (Docker, ClipCascade)
                                         └─ headscale.kfazilov.online → 127.0.0.1:8080 (headscale + DERP на /derp)
клиенты tailnet ──udp──▶ :3478 (STUN встроенного DERP, напрямую в headscale)
```

- **Caddy** держит 80/443 и сам получает сертификаты Let's Encrypt для обоих доменов. Раньше 80/443 занимал сам headscale со встроенным Let's Encrypt. Теперь он слушает только `127.0.0.1:8080`, без TLS.
- **Встроенный DERP** в headscale включён (регион `999 / ru / headscale-ru`), DERP-серверы Tailscale из карты убраны. Relay-трафик идёт через Caddy на `/derp`, STUN слушает UDP 3478 напрямую.
- **ClipCascade** в Docker, `/opt/clipcascade`: режим через сервер (не P2P), лимит сообщения 25 MiB, регистрация выключена. База H2 зашифрована и лежит в `/opt/clipcascade/cc_users`.

## Файлы

| Файл | Куда на сервере |
|---|---|
| `docker-compose.yml` | `/opt/clipcascade/docker-compose.yml` |
| `.env` (не в git) | `/opt/clipcascade/.env`, `chmod 600` |
| `Caddyfile` | `/etc/caddy/Caddyfile` |
| `headscale-config.patch` | что поменяно в `/etc/headscale/config.yaml` (diff от `config.yaml.bak-pre-caddy`) |

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

4. **headscale за Caddy и свой DERP**: в `/etc/headscale/config.yaml` поменять строки, как в `headscale-config.patch`:
   ```yaml
   listen_addr: 127.0.0.1:8080
   tls_letsencrypt_hostname: ""
   derp:
     server:
       enabled: true
       region_code: "ru"
       region_name: "headscale-ru"
       ipv4: <IPv4 сервера>
       # ipv6 не указывать: у VPS нет публичного IPv6
     urls: []
   ```
   UDP 3478 (STUN) должен быть открыт снаружи, в том числе в файрволе хостинга, если он есть.
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
   DERP: `curl -s -o /dev/null -w '%{http_code}\n' https://headscale.kfazilov.online/derp/probe` даёт 200. На подключённом клиенте `tailscale netcheck` показывает регион `ru`. Пока клиент не подключён (`tailscale up`), netcheck показывает стандартную карту Tailscale, это нормально.

7. **Админка**: `https://clip.kfazilov.online`, вход под стандартным админом из README ClipCascade. Сразу сменить пароль и создать пользователя для устройств.

**Откат headscale**: `sudo systemctl disable --now caddy`, вернуть бэкап `config.yaml.bak-pre-caddy`, `sudo systemctl restart headscale`.

## Обновить

ClipCascade: поменять тег образа в `docker-compose.yml` (здесь и на сервере), затем
```sh
cd /opt/clipcascade && sudo docker compose pull && sudo docker compose up -d
```
После этого перелогиниться на всех устройствах (см. «Почему так»). Поменять Caddyfile: `sudo systemctl reload caddy` после замены файла, ClipCascade это не задевает.

## Почему так

- **Любой рестарт контейнера разлогинивает все клиенты.** ClipCascade держит сессии в памяти. Сохранить их на диск (`SERVER_SERVLET_SESSION_PERSISTENT`) не получается: объект пользователя в ClipCascade не сериализуется, и Tomcat при загрузке падает с `StreamCorruptedException`. Клиент на Linux сам заново не входит, а бесконечно стучится со старой cookie: в `~/.local/share/clipcascade/clipcascade_log.log` пишет `Invalid redirect target .../login`. После обновления образа, перезагрузки сервера или `docker compose restart` нужно перелогиниться на ноутбуке (команда в README dotfiles, раздел ClipCascade) и проверить телефон. Поэтому без нужды контейнер не перезапускать.
- **`SERVER_FORWARD_HEADERS_STRATEGY=native`**: без этого Spring не видит `X-Forwarded-Proto` от Caddy и редиректит на `http://`.
- **Образ `0.7.0`, а не `latest`**: у сервера своя нумерация версий, клиенты 3.x с ним совместимы. `latest` при `pull` обновил бы сервер незаметно.
- **Порт `127.0.0.1:8081`**: снаружи ClipCascade доступен только через Caddy с TLS.
- **Свой DERP вместо DERP-серверов Tailscale.** Если телефон на LTE за CGNAT и Raspberry Pi дома за NAT, прямое соединение часто не пробивается, и трафик уходит в relay. Зарубежные DERP Tailscale из РФ режутся или тормозят: SSH ещё работал, exit node через Pi нет. С DERP на `headscale-ru` всё заработало. `urls: []` можно ставить только при включённом встроенном DERP, иначе headscale не стартует с `initial DERPMap is empty`.
- **`ipv6` в секции DERP не задан**: у VPS только link-local IPv6. Значение-заглушка из примера (`2001:db8::1`) попало бы в DERP map, и клиенты пытались бы подключиться по несуществующему адресу.
- **Android с exit node без интернета**: выключить «Частный DNS» в настройках телефона. Иначе Android ходит на DoT мимо MagicDNS, и через exit node перестают резолвиться имена.
