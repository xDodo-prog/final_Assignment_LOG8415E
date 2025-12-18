#!/bin/bash
set -euo pipefail

echo "[GATEKEEPER] Starting gatekeeper user-data"

APP_DIR="/opt/gatekeeper"
VENV_DIR="${APP_DIR}/venv"
PORT="8080"
PROXY_URL="http://10.0.2.15:5000"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y python3-venv python3-full

mkdir -p "${APP_DIR}"
chown -R ubuntu:ubuntu "${APP_DIR}"

# venv (PEP 668 safe)
sudo -u ubuntu python3 -m venv "${VENV_DIR}"
"${VENV_DIR}/bin/pip" install --upgrade pip
"${VENV_DIR}/bin/pip" install flask requests

# Gatekeeper app: forwards requests to Proxy + blocks dangerous SQL
cat > "${APP_DIR}/gatekeeper.py" <<PY
from flask import Flask, request, jsonify
import requests

app = Flask(__name__)
PROXY_URL = "${PROXY_URL}"

def is_dangerous(sql: str) -> bool:
    s = (sql or "").strip().lower()
    return s.startswith(("drop", "truncate", "alter"))

@app.route("/", methods=["GET"])
def health():
    return jsonify({"status": "gatekeeper up", "proxy": PROXY_URL}), 200

@app.route("/query", methods=["POST"])
def query():
    payload = request.get_json(silent=True) or {}
    sql = payload.get("query", "")

    if not sql:
        return jsonify({"error": "Missing field: query"}), 400

    # Security: block destructive commands
    if is_dangerous(sql):
        return jsonify({"error": "Dangerous SQL command not allowed"}), 403

    try:
        r = requests.post(f"{PROXY_URL}/query", json=payload, timeout=10)
        return (r.text, r.status_code, {"Content-Type": "application/json"})
    except requests.RequestException as e:
        return jsonify({"error": f"Proxy unreachable: {str(e)}"}), 502

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int("${PORT}"))
PY

chown -R ubuntu:ubuntu "${APP_DIR}"
chmod +x "${APP_DIR}/gatekeeper.py"

# systemd service
cat > /etc/systemd/system/gatekeeper.service <<EOF
[Unit]
Description=Gatekeeper Flask Service
After=network.target

[Service]
User=ubuntu
WorkingDirectory=${APP_DIR}
ExecStart=${VENV_DIR}/bin/python ${APP_DIR}/gatekeeper.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now gatekeeper.service

echo "[GATEKEEPER] Gatekeeper installed and started."
systemctl --no-pager status gatekeeper.service || true
