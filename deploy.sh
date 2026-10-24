#!/usr/bin/env bash
# Push docker-compose.yml, .env and Caddyfile to the server, then apply them.
# Usage: ./deploy.sh [ssh-host]   (default: headscale-ru)
set -euo pipefail
cd "$(dirname "$0")"

host=${1:-headscale-ru}
[[ -f .env ]] || { echo ".env missing, see .env.example" >&2; exit 1; }

tmp=$(ssh "$host" mktemp -d)
scp -q docker-compose.yml .env Caddyfile "$host:$tmp/"
ssh "$host" bash -s -- "$tmp" <<'EOF'
set -euo pipefail
tmp=$1
trap 'rm -rf "$tmp"' EXIT

sudo install -Dm644 "$tmp/docker-compose.yml" /opt/clipcascade/docker-compose.yml
sudo install -Dm600 "$tmp/.env" /opt/clipcascade/.env
caddy validate --config "$tmp/Caddyfile" --adapter caddyfile >/dev/null
sudo install -Dm644 "$tmp/Caddyfile" /etc/caddy/Caddyfile

sudo systemctl reload caddy
cd /opt/clipcascade
sudo docker compose pull -q
sudo docker compose up -d
EOF

for url in https://clip.kfazilov.online/login https://headscale.kfazilov.online/health; do
    for _ in $(seq 1 30); do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" || true)
        [[ $code == 200 ]] && break
        sleep 2
    done
    echo "$url -> $code"
done
