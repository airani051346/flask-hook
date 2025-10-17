#!/usr/bin/env bash
set -euo pipefail

# ==========
# Defaults (override via flags or env)
# ==========
APP_NAME="${APP_NAME:-captainhook}"
APP_DIR="${APP_DIR:-/opt/$APP_NAME}"
APP_USER="${APP_USER:-www-data}"
BIND_IP="${BIND_IP:-127.0.0.1}"     # safer than binding to a public IP; set to 10.0.6.8 if you really need it
PORT="${PORT:-5009}"
SECRET_TOKEN="${SECRET_TOKEN:-mysecrettoken123}"

# For TLS + certbot:
DOMAIN="${DOMAIN:-}"                # e.g., clientgw-xxxx.westeurope.cloudapp.azure.com
CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"  # required for non-interactive certbot
USE_CERTBOT="${USE_CERTBOT:-true}"  # set to false to skip certbot even if DOMAIN is set

# ==========
# Flags parsing (simple)
# ==========
for arg in "$@"; do
  case "$arg" in
    --app-name=*)        APP_NAME="${arg#*=}" ;;
    --app-dir=*)         APP_DIR="${arg#*=}" ;;
    --user=*)            APP_USER="${arg#*=}" ;;
    --bind-ip=*)         BIND_IP="${arg#*=}" ;;
    --port=*)            PORT="${arg#*=}" ;;
    --secret=*)          SECRET_TOKEN="${arg#*=}" ;;
    --domain=*)          DOMAIN="${arg#*=}" ;;
    --email=*)           CERTBOT_EMAIL="${arg#*=}" ;;
    --use-certbot=*)     USE_CERTBOT="${arg#*=}" ;;
    --help|-h)
      cat <<EOF
Usage: sudo bash $0 [options]

Options:
  --app-name=<name>           (default: $APP_NAME)
  --app-dir=<path>            (default: $APP_DIR)
  --user=<system user>        (default: $APP_USER)
  --bind-ip=<ip>              (default: $BIND_IP)
  --port=<port>               (default: $PORT)
  --secret=<token>            (default: $SECRET_TOKEN)
  --domain=<fqdn>             (default: empty = no TLS)
  --email=<email>             (certbot email; required for non-interactive)
  --use-certbot=<true|false>  (default: $USE_CERTBOT)

Examples:
  sudo bash $0 --domain=example.com --email=you@example.com
  sudo bash $0 --bind-ip=10.0.6.8 --secret=mysecrettoken123
EOF
      exit 0
      ;;
  esac
done

# ==========
# Root check
# ==========
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo)."
  exit 1
fi

# ==========
# Packages
# ==========
echo "[1/8] Installing system packages…"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y python3 python3-venv python3-pip nginx

# Certbot packages only if we plan to use TLS
if [[ -n "$DOMAIN" && "$USE_CERTBOT" == "true" ]]; then
  apt-get install -y certbot python3-certbot-nginx
fi

# Optional firewall rule if ufw is active
if command -v ufw >/dev/null 2>&1; then
  if ufw status | grep -q "Status: active"; then
    echo "[i] UFW active: allowing 'Nginx Full'"
    ufw allow 'Nginx Full' || true
  fi
fi

# ==========
# App layout
# ==========
echo "[2/8] Creating app directories…"
APP_SRC="$APP_DIR/app"
APP_VENV="$APP_DIR/venv"
mkdir -p "$APP_SRC"
mkdir -p /var/www/certbot/.well-known/acme-challenge
chown -R "$APP_USER":"$APP_USER" /var/www/certbot || true

# ==========
# Flask app
# ==========
echo "[3/8] Writing Flask webhook (captainhook.py)…"
cat > "$APP_SRC/captainhook.py" <<'PYAPP'
from flask import Flask, request, abort, jsonify
import os

app = Flask(__name__)
SECRET_TOKEN = os.getenv("SECRET_TOKEN", "mysecrettoken123")

@app.route('/webhook', methods=['POST'])
def webhook():
    token = request.headers.get('X-Webhook-Token')
    if token != SECRET_TOKEN:
        abort(403)  # Forbidden
    data = request.get_json(silent=True) or {}
    print("Authenticated webhook data:", data, flush=True)
    response = {
        "status": "success",
        "message": "Webhook received successfully",
        "received_data": data
    }
    return jsonify(response), 200

if __name__ == '__main__':
    app.run(host=os.getenv("BIND_IP", "127.0.0.1"), port=int(os.getenv("PORT", "5009")))
PYAPP

# ==========
# Python venv + deps
# ==========
echo "[4/8] Creating Python venv and installing Flask + Gunicorn…"
python3 -m venv "$APP_VENV"
"$APP_VENV/bin/pip" install --upgrade pip
"$APP_VENV/bin/pip" install Flask gunicorn

# ==========
# Environment file for service
# ==========
echo "[5/8] Creating environment file…"
ENV_FILE="/etc/${APP_NAME}.env"
cat > "$ENV_FILE" <<EOF
SECRET_TOKEN=$SECRET_TOKEN
BIND_IP=$BIND_IP
PORT=$PORT
EOF
chmod 640 "$ENV_FILE"
chown root:"$APP_USER" "$ENV_FILE" || true

# ==========
# systemd service (Gunicorn)
# ==========
echo "[6/8] Creating systemd service…"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=${APP_NAME} Flask webhook (Gunicorn)
After=network.target

[Service]
User=$APP_USER
Group=$APP_USER
WorkingDirectory=$APP_SRC
EnvironmentFile=-$ENV_FILE
ExecStart=$APP_VENV/bin/gunicorn --workers 2 --bind \${BIND_IP}:\${PORT} captainhook:app
Restart=on-failure
RestartSec=2

# If you log with journald:
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$APP_NAME"
systemctl restart "$APP_NAME"

sleep 1
systemctl --no-pager --full status "$APP_NAME" || true

# ==========
# NGINX site
# ==========
echo "[7/8] Creating NGINX site…"
SITE_FILE="/etc/nginx/sites-available/${APP_NAME}.conf"
cat > "$SITE_FILE" <<EOF
server {
    listen 80;
    server_name ${DOMAIN:-_};

    # ACME challenge for Let's Encrypt
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # Proxy the webhook
    location /webhook {
        proxy_pass http://${BIND_IP}:${PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Webhook-Token \$http_x_webhook_token;
        proxy_http_version 1.1;
        proxy_buffering off;
    }

    # Optional default root (not strictly needed)
    location / {
        return 404;
    }
}
EOF

ln -sf "$SITE_FILE" "/etc/nginx/sites-enabled/${APP_NAME}.conf"

# Disable the default site if enabled (optional but avoids conflicts)
if [[ -e /etc/nginx/sites-enabled/default ]]; then
  rm -f /etc/nginx/sites-enabled/default
fi

nginx -t
systemctl reload nginx

# ==========
# Certbot (optional)
# ==========
if [[ -n "$DOMAIN" && "$USE_CERTBOT" == "true" ]]; then
  if [[ -z "$CERTBOT_EMAIL" ]]; then
    echo "[!] DOMAIN provided but CERTBOT_EMAIL is empty. Skipping certbot."
  else
    echo "[8/8] Requesting Let's Encrypt certificate for $DOMAIN …"
    # This will modify the NGINX site to add ssl_* directives and enable HTTPS + redirect
    certbot --nginx -d "$DOMAIN" --agree-tos -m "$CERTBOT_EMAIL" --non-interactive --redirect || {
      echo "[!] Certbot failed. Check DNS and inbound access to TCP/80 from Let's Encrypt."
    }
    nginx -t && systemctl reload nginx
  fi
else
  echo "[i] Skipping certbot (no DOMAIN or USE_CERTBOT=false). HTTP only."
fi

echo ""
echo "==================== SUCCESS ===================="
echo "Service: systemctl status ${APP_NAME}"
echo "Logs:    journalctl -u ${APP_NAME} -f"
echo ""
if [[ -n "$DOMAIN" && "$USE_CERTBOT" == "true" && -n "$CERTBOT_EMAIL" ]]; then
  echo "Test HTTPS webhook:"
  echo "  curl -X POST https://${DOMAIN}/webhook \\"
else
  echo "Test HTTP webhook:"
  # If you bound to 127.0.0.1 you may want to curl from localhost or proxy via NGINX on same host
  TEST_HOST="${DOMAIN:-localhost}"
  echo "  curl -X POST http://${TEST_HOST}/webhook \\"
fi
echo "       -H 'Content-Type: application/json' \\"
echo "       -H 'X-Webhook-Token: ${SECRET_TOKEN}' \\"
echo "       -d '{\"event\":\"test\",\"value\":123}'"
echo "================================================="
