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
import os
import random
import time
import socket

app = Flask(__name__)

# Defaults (can be overridden by systemd Environment=...)
MASTER_HOST = os.getenv("MASTER_HOST", "10.0.3.10")
WORKER_HOSTS = [h.strip() for h in os.getenv("WORKER_HOSTS", "10.0.3.11,10.0.3.12").split(",") if h.strip()]

DB_NAME = os.getenv("DB_NAME", "sakila")
DB_USER = os.getenv("DB_USER", "admin")
DB_PASS = os.getenv("DB_PASS", "Password123")

# Default strategy if no header override
DEFAULT_STRATEGY = os.getenv("PROXY_STRATEGY", "round_robin").strip().lower()

# Latency picker cache (avoid probing each request)
LATENCY_CACHE_TTL = float(os.getenv("LATENCY_CACHE_TTL", "2.0"))

_rr_lock = Lock()
_worker_index = 0

_latency_cache = {"ts": 0.0, "host": None}


def is_write_query(sql: str) -> bool:
    s = (sql or "").strip().lower()
    # Consider these as reads:
    if s.startswith(("select", "show", "describe", "explain")):
        return False
    # Everything else treated as write:
    return True


def tcp_latency_ms(host: str, port: int = 3306, timeout: float = 0.5) -> float:
    """TCP connect time in ms (works in VPC without ICMP)."""
    t0 = time.perf_counter()
    try:
        with socket.create_connection((host, port), timeout=timeout):
            pass
        return (time.perf_counter() - t0) * 1000.0
    except OSError:
        return float("inf")


def pick_worker_round_robin() -> str:
    global _worker_index
    with _rr_lock:
        h = WORKER_HOSTS[_worker_index]
        _worker_index = (_worker_index + 1) % len(WORKER_HOSTS)
    return h


def pick_worker_random() -> str:
    return random.choice(WORKER_HOSTS)


def pick_worker_latency() -> str:
    now = time.time()
    if _latency_cache["host"] and (now - _latency_cache["ts"] < LATENCY_CACHE_TTL):
        return _latency_cache["host"]

    best_host = None
    best_ms = float("inf")
    for h in WORKER_HOSTS:
        ms = tcp_latency_ms(h)
        if ms < best_ms:
            best_ms = ms
            best_host = h

    if not best_host:
        best_host = WORKER_HOSTS[0]

    _latency_cache["ts"] = now
    _latency_cache["host"] = best_host
    return best_host


def choose_target(sql: str, strategy: str) -> str:
    # Writes always go to master
    if is_write_query(sql):
        return MASTER_HOST

    # Reads routing depends on strategy
    if strategy == "direct":
        return MASTER_HOST
    if strategy == "random":
        return pick_worker_random()
    if strategy == "latency":
        return pick_worker_latency()
    if strategy == "round_robin":
        return pick_worker_round_robin()

    # fallback
    return pick_worker_round_robin()


def execute_query(host: str, sql: str):
    conn = mysql.connector.connect(
        host=host,
        user=DB_USER,
        password=DB_PASS,
        database=DB_NAME,
        autocommit=True,
    )
    cur = conn.cursor(dictionary=True)
    cur.execute(sql)

    if cur.with_rows:
        out = cur.fetchall()
    else:
        out = {"affected_rows": cur.rowcount}

    cur.close()
    conn.close()
    return out


@app.route("/", methods=["GET"])
def health():
    return jsonify({
        "status": "proxy up",
        "default_strategy": DEFAULT_STRATEGY,
        "master": MASTER_HOST,
        "workers": WORKER_HOSTS,
        "latency_cache_ttl": LATENCY_CACHE_TTL,
    }), 200


@app.route("/query", methods=["POST"])
def query():
    payload = request.get_json(silent=True) or {}
    sql = payload.get("query", "")
    if not sql:
        return jsonify({"error": "Missing field: query"}), 400

    # Allow Gatekeeper to override strategy per-request via header
    strategy = request.headers.get("X-Proxy-Strategy", DEFAULT_STRATEGY).strip().lower()

    target = choose_target(sql, strategy)
    try:
        res = execute_query(target, sql)
        return jsonify({"strategy": strategy, "target_host": target, "result": res}), 200
    except Exception as e:
        return jsonify({"strategy": strategy, "target_host": target, "error": str(e)}), 500


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