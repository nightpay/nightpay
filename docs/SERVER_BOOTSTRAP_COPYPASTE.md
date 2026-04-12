# Server Bootstrap Copy/Paste Template

Use this as a safe copy/paste baseline for deploying and starting NightPay on a VPS.
Replace placeholders before running.

## 1) SSH sanity check

```bash
ssh -o StrictHostKeyChecking=accept-new -i <SSH_KEY_PATH> root@<HOST> \
  "echo connected && uname -a && uname -m"
```

Expected arch: `x86_64`.

## 2) Sync repo to server

Run from local repo root:

```bash
tar \
  --exclude=.git \
  --exclude=node_modules \
  --exclude=ui/node_modules \
  --exclude=.agent-playground \
  --exclude=.env \
  --exclude=.env.* \
  --exclude=.private \
  --exclude=hetzner_* \
  -czf - . \
| ssh -i <SSH_KEY_PATH> root@<HOST> "\
    set -e; \
    mkdir -p /opt/nightpay; \
    tar -xzf - -C /opt/nightpay; \
    if ! id -u deploy >/dev/null 2>&1; then useradd -m -s /bin/bash -G sudo,docker deploy; fi; \
    chown -R deploy:deploy /opt/nightpay; \
    find /opt/nightpay -type f -name '*.sh' -exec sed -i 's/\r$//' {} +"
```

## 3) Install dependencies + initialize runtime

```bash
ssh -i <SSH_KEY_PATH> root@<HOST> '
  set -e
  su - deploy -c "cd /opt/nightpay && npm install --no-audit --no-fund"
  su - deploy -c "cd /opt/nightpay/ui && npm install --no-audit --no-fund"
  su - deploy -c "cd /opt/nightpay && bash scripts/agent-playground-setup.sh init"
'
```

## 4) Fill env once

```bash
ssh -i <SSH_KEY_PATH> root@<HOST>
su - deploy
cd /opt/nightpay
cp -n .agent-playground.env.example .agent-playground.env
nano .agent-playground.env
```

Required fields:
- `MASUMI_API_KEY`
- `OPERATOR_ADDRESS`
- `RECEIPT_CONTRACT_ADDRESS`
- `BRIDGE_URL` (leave empty/remove for stub mode)

## 5) Start and verify

```bash
bash scripts/agent-playground-setup.sh stop
bash scripts/agent-playground-setup.sh start
bash scripts/agent-playground-setup.sh doctor
curl -sS http://localhost:8090/availability
curl -sS -o /dev/null -w "%{http_code}\n" http://localhost:3333/
```

If Caddy + DNS are already configured for production, verify the public hosts too:

```bash
curl -sS https://api.nightpay.dev/availability
curl -sS -o /dev/null -w "%{http_code}\n" https://board.nightpay.dev/
curl -sS https://bridge.nightpay.dev/health | python3 -m json.tool
```

## 6) Masumi quickstart (if not already installed)

```bash
git clone https://github.com/masumi-network/masumi-services-dev-quickstart.git /opt/masumi-services-dev-quickstart
cd /opt/masumi-services-dev-quickstart
cp .env.example .env
# Fill BLOCKFROST_API_KEY_PREPROD + ADMIN_KEY
docker compose up -d
curl -sS http://localhost:3001/api/v1/health
curl -sS http://localhost:3000/api/v1/health
```

## 7) Daily ops

```bash
ssh -i <SSH_KEY_PATH> root@<HOST>
su - deploy
cd /opt/nightpay
bash scripts/agent-playground-setup.sh doctor
tail -n 80 .agent-playground/logs/mip003.log
tail -n 80 .agent-playground/logs/ui.log
```
