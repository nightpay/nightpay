#!/usr/bin/env bash
# Remote installer. Owns only nightpay-marketplace and its dedicated Caddy import.
set -euo pipefail
RELEASE="${1:?release directory required}"
DOMAIN="${2:-nightpay.dev}"
[[ "$RELEASE" =~ ^/opt/nightpay-marketplace/releases/[A-Za-z0-9T-]+$ ]] || exit 1
[[ "$DOMAIN" =~ ^[a-z0-9.-]+$ ]] || exit 1
BASE=/opt/nightpay-marketplace
test -f "$RELEASE/ui/index.html"
test -f "$RELEASE/skills/nightpay/scripts/mip003-server.sh"
command -v caddy >/dev/null
grep -q 'import imports/\*.caddy' /etc/caddy/Caddyfile || { echo 'Dedicated Caddy import is not configured'; exit 1; }
id nightpay >/dev/null 2>&1 || useradd --system --home /var/lib/nightpay --shell /usr/sbin/nologin nightpay
install -d -o nightpay -g nightpay -m 700 /var/lib/nightpay
install -d -m 750 -o root -g nightpay /etc/nightpay
if [[ ! -f /etc/nightpay/marketplace.env ]]; then
  python3 - <<'PY'
import os, secrets
path='/etc/nightpay/marketplace.env'
fd=os.open(path, os.O_WRONLY|os.O_CREAT|os.O_EXCL, 0o640)
with os.fdopen(fd,'w') as f:
    f.write('JOB_TOKEN_SECRET='+secrets.token_hex(32)+'\nOPERATOR_SECRET_KEY='+secrets.token_hex(32)+'\n')
    f.write('DATA_DIR=/var/lib/nightpay\nMIP_BIND_HOST=127.0.0.1\nAGENT_IDENTITY_ENFORCE=1\nMANAGEMENT_LLM_ENABLED=0\nMIDNIGHT_NETWORK=preprod\nX402_ENABLED=0\n')
PY
fi
chown root:nightpay /etc/nightpay/marketplace.env
chmod 640 /etc/nightpay/marketplace.env
# Isolated Python environment; no modification of other services' dependencies.
test -x "$BASE/venv/bin/python3" || python3 -m venv "$BASE/venv"
"$BASE/venv/bin/pip" install --disable-pip-version-check 'cryptography==50.0.1'
PREVIOUS="$(readlink -f "$BASE/current" || true)"
SNIPPET=/etc/caddy/imports/nightpay.caddy
BACKUP="$BASE/caddy-before-$(basename "$RELEASE").txt"
HAD_SNIPPET=0
if [[ -f "$SNIPPET" ]]; then cp "$SNIPPET" "$BACKUP"; HAD_SNIPPET=1; fi
rollback() {
  if [[ -n "$PREVIOUS" && "$PREVIOUS" != "$BASE/current" && -d "$PREVIOUS" ]]; then
    ln -sfn "$PREVIOUS" "$BASE/current"
    systemctl restart nightpay-marketplace || true
  else
    systemctl stop nightpay-marketplace || true
  fi
  if [[ "$HAD_SNIPPET" == 1 ]]; then cp "$BACKUP" "$SNIPPET"; else rm -f "$SNIPPET"; fi
  caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 && systemctl reload caddy || true
  echo 'NightPay marketplace deploy failed; prior routing restored.' >&2
}
trap rollback ERR
ln -sfn "$RELEASE" "$BASE/current"
cat > /etc/systemd/system/nightpay-marketplace.service <<'UNIT'
[Unit]
Description=NightPay agent marketplace API (settlement configured separately)
After=network.target
[Service]
User=nightpay
Group=nightpay
WorkingDirectory=/opt/nightpay-marketplace/current
EnvironmentFile=/etc/nightpay/marketplace.env
Environment=PATH=/opt/nightpay-marketplace/venv/bin:/usr/bin:/bin
ExecStart=/bin/bash /opt/nightpay-marketplace/current/skills/nightpay/scripts/mip003-server.sh 8090
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/nightpay
[Install]
WantedBy=multi-user.target
UNIT
cat > "$SNIPPET" <<CADDY
$DOMAIN, www.$DOMAIN, board.$DOMAIN, docs.$DOMAIN {
  encode zstd gzip
  handle_path /mip/* {
    reverse_proxy 127.0.0.1:8090
  }
  handle /ontology* {
    reverse_proxy 127.0.0.1:8090
  }
  handle /api/* {
    header Content-Type application/json
    respond "{\"error\":\"Settlement bridge is awaiting operator configuration\"}" 503
  }
  handle {
    root * $BASE/current/ui
    try_files {path} /index.html
    file_server
  }
}
api.$DOMAIN {
  reverse_proxy 127.0.0.1:8090
}
CADDY
caddy validate --config /etc/caddy/Caddyfile >/dev/null
systemctl daemon-reload
systemctl enable nightpay-marketplace >/dev/null
systemctl restart nightpay-marketplace
for attempt in {1..20}; do
  if curl -fsS http://127.0.0.1:8090/availability >/dev/null; then break; fi
  sleep 1
done
curl -fsS http://127.0.0.1:8090/availability >/dev/null
systemctl reload caddy
trap - ERR
echo "Marketplace release installed: $RELEASE"
echo 'Settlement is not activated by this installer. Confirm escrow and receipts separately.'
