#!/bin/bash
set -euo pipefail

echo "[PROXY] Starting proxy user-data"

# ---------
# Variables (adapt to your setup if needed)
# ---------
PROXY_DIR="/opt/proxy"
VENV_DIR="${PROXY_DIR}/venv"

MANAGER_HOST="10.0.3.10"
WORKER1_HOST="10.0.3.11"
WORKER2_HOST="10.0.3.12"

DB_NAME="sakila"
DB_USER="admin"
DB_PASS="Password123"

PROXY_PORT="5000"

# ---------
# Packages
# ---------
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y python3-venv python3-full

# ---------
# App directory
# ---------
mkdir -p "${PROXY_DIR}"
chown -R ubuntu:ubuntu "${PROXY_DIR}"

# ---------
# Virtual environment (PEP 668 safe)
# ---------
sudo -u ubuntu python3 -m venv "${VENV_DIR}"
"${VENV_DIR}/bin/pip" install --upgrade pip
"${VENV_DIR}/bin/pip" install flask mysql-connector-python

# ---------
# Write proxy app
# ---------
cat > "${PROXY_DIR}/proxy.py" <<'PY'
from flask import Flask, request, jsonify
import mysql.connector
from threading import Lock

app = Flask(__name__)

# =========================
# DB config (fixed IPs)
# =========================
MANAGER_DB = {
    "host": "10.0.3.10",
    "user": "admin",
    "password": "Password123",
    "database": "sakila",
}

WORKERS_DB = [
    {"host": "10.0.3.11", "user": "admin", "password": "Password123", "database": "sakila"},
    {"host": "10.0.3.12", "user": "admin", "password": "Password123", "database": "sakila"},
]

_worker_index = 0
_rr_lock = Lock()

def is_write_query(q: str) -> bool:
    q = q.strip().lower()
    return q.startswith(("insert", "update", "delete", "create", "drop", "alter", "truncate"))

def pick_worker_round_robin():
    global _worker_index
    with _rr_lock:
        w = WORKERS_DB[_worker_index]
        _worker_index = (_worker_index + 1) % len(WORKERS_DB)
    return w

def execute_query(db_cfg: dict, sql: str):
    conn = mysql.connector.connect(**db_cfg)
    cur = conn.cursor(dictionary=True)
    cur.execute(sql)

    if is_write_query(sql):
        conn.commit()
        out = {"affected_rows": cur.rowcount}
    else:
        out = cur.fetchall()

    cur.close()
    conn.close()
    return out

@app.route("/", methods=["GET"])
def health():
    return jsonify({"status": "proxy up"}), 200

@app.route("/query", methods=["POST"])
def query():
    payload = request.get_json(silent=True) or {}
    sql = payload.get("query")
    if not sql:
        return jsonify({"error": "Missing field: query"}), 400

    try:
        if is_write_query(sql):
            target = MANAGER_DB["host"]
            res = execute_query(MANAGER_DB, sql)
        else:
            w = pick_worker_round_robin()
            target = w["host"]
            res = execute_query(w, sql)

        return jsonify({"target_host": target, "result": res}), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
PY

chown -R ubuntu:ubuntu "${PROXY_DIR}"
chmod +x "${PROXY_DIR}/proxy.py"

# ---------
# systemd service
# ---------
cat > /etc/systemd/system/proxy.service <<EOF
[Unit]
Description=Proxy Flask Service
After=network.target

[Service]
User=ubuntu
WorkingDirectory=${PROXY_DIR}
ExecStart=${VENV_DIR}/bin/python ${PROXY_DIR}/proxy.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now proxy.service

echo "[PROXY] Proxy service installed and started."
systemctl --no-pager status proxy.service || true