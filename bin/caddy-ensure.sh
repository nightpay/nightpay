#!/usr/bin/env bash
# Ensure Caddy is validating, running, and listening on 80/443 (production TLS front door).
# Intended to run on the VPS as root during deploy or manual recovery.
set -euo pipefail

CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"

if ! command -v caddy >/dev/null 2>&1; then
  echo "WARN: caddy binary not found; skipping TLS ensure"
  exit 0
fi

if [[ ! -f "$CADDYFILE" ]]; then
  echo "ERROR: Caddyfile not found at $CADDYFILE" >&2
  exit 1
fi

echo "Validating $CADDYFILE..."
caddy validate --config "$CADDYFILE"

if command -v systemctl >/dev/null 2>&1; then
  systemctl enable caddy 2>/dev/null || true
  if systemctl is-active --quiet caddy; then
    systemctl reload caddy
  else
    systemctl start caddy
  fi
  if ! systemctl is-active --quiet caddy; then
    echo "ERROR: caddy.service failed to stay active" >&2
    journalctl -u caddy -n 80 --no-pager >&2 || true
    exit 1
  fi
else
  echo "WARN: systemctl unavailable; assuming Caddy is managed externally"
fi

missing_ports=()
for port in 80 443; do
  if ! ss -ltn 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$"' | grep -q .; then
    missing_ports+=("$port")
  fi
done

if [[ ${#missing_ports[@]} -gt 0 ]]; then
  echo "ERROR: Caddy is not listening on port(s): ${missing_ports[*]}" >&2
  ss -ltnp 2>/dev/null | grep -E ':(80|443)\b' >&2 || true
  journalctl -u caddy -n 50 --no-pager >&2 || true
  exit 1
fi

echo "caddy_tls=ok (listening on 80/443)"
