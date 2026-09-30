#!/usr/bin/env bash
# Deploy the directory and private-order API independently of settlement services.
set -euo pipefail
HOST="${1:?Usage: bash bin/deploy-marketplace.sh <ssh-host> [domain]}"
DOMAIN="${2:-nightpay.dev}"
[[ "$HOST" =~ ^[A-Za-z0-9_.@:-]+$ ]] || { echo 'Invalid SSH host' >&2; exit 1; }
[[ "$DOMAIN" =~ ^[a-z0-9.-]+$ ]] || { echo 'Invalid domain' >&2; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test -f "$ROOT/ui/dist/index.html" || { echo 'Build ui first with npm ci and npm run build' >&2; exit 1; }
RELEASE="$(date -u +%Y%m%dT%H%M%SZ)-$(git -C "$ROOT" rev-parse --short HEAD)"
REMOTE="/opt/nightpay-marketplace/releases/$RELEASE"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=20 "$HOST")
"${SSH[@]}" "mkdir -p '$REMOTE/ui'"
tar -C "$ROOT" -cf - skills/nightpay/scripts/mip003-server.sh skills/nightpay/ontology \
  bin/install-marketplace.sh | "${SSH[@]}" "tar -xf - -C '$REMOTE'"
tar -C "$ROOT/ui/dist" -cf - . | "${SSH[@]}" "tar -xf - -C '$REMOTE/ui'"
"${SSH[@]}" "sed -i 's/\r$//' '$REMOTE/bin/install-marketplace.sh' '$REMOTE/skills/nightpay/scripts/mip003-server.sh'; bash '$REMOTE/bin/install-marketplace.sh' '$REMOTE' '$DOMAIN'"
