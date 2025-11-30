#!/bin/bash
set -e

#-----------------------------------
# Update & Python installation
#-----------------------------------

apt-get update -y
apt-get install -y python3 python3-pip

pip3 install flask mysql-connector-python requests

mkdir -p /opt/proxy
cd /opt/proxy


#-----------------------------------
# Python Script
#-----------------------------------

cat << 'EOF' > /opt/proxy/proxy.py
#!/usr/bin/env python3
from flask import Flask, request, jsonify
import mysql.connector
from mysql.connector import Error
import os
import random
import time
WORKER_INDEX = 0

app = Flask(__name__)

INTERNAL_SHARED_SECRET = os.getenv("INTERNAL_SHARED_SECRET", "db-shared-secret")
STRATEGY = os.getenv("PROXY_STRATEGY", "ROUND_ROBIN")

MANAGER_DB = {
    "host": os.getenv("MANAGER_HOST", "10.0.3.10"),
    "user": os.getenv("DB_USER", "admin"),
    "password": os.getenv("DB_PASSWORD", "Password123"),
    "database": os.getenv("DB_NAME", "sakila")
}
WORKERS_DB = [
    {
        "host": os.getenv("WORKER1_HOST", "10.0.3.11"),
        "user": os.getenv("DB_USER", "admin"),
        "password": os.getenv("DB_PASSWORD", "Password123"),
        "database": os.getenv("DB_NAME", "sakila")
    },
    {
        "host": os.getenv("WORKER2_HOST", "10.0.3.12"),
        "user": os.getenv("DB_USER", "admin"),
        "password": os.getenv("DB_PASSWORD", "Password123"),
        "database": os.getenv("DB_NAME", "sakila")
    },
]

def normalize_query(q: str) -> str:
    return (q or "").strip()

def is_write_query(query: str) -> bool:
    q = normalize_query(query).upper()
    if not q:
        return False
    first_word = q.split()[0]
    return first_word in {"INSERT", "UPDATE", "DELETE", "REPLACE", "CREATE", "ALTER", "DROP"}

def execute_query(db_config: dict, query: str):
    try:
        conn = mysql.connector.connect(**db_config)
        cursor = conn.cursor(dictionary=True)
        cursor.execute(query)
        if is_write_query(query):
            conn.commit()
            result = {"rows": [], "rowcount": cursor.rowcount}
        else:
            rows = cursor.fetchall()
            result = {"rows": rows, "rowcount": cursor.rowcount}
        cursor.close()
        conn.close()
        return result, None
    except Error as e:
        return None, str(e)



def choose_worker_round_robin():
    global WORKER_INDEX
    worker = WORKERS_DB[WORKER_INDEX]
    WORKER_INDEX = (WORKER_INDEX + 1) % len(WORKERS_DB)
    return worker

def select_db_for_query(query: str):
    if is_write_query(query):
        return MANAGER_DB

    return choose_worker_round_robin()

def is_internal_call(req) -> bool:
    secret = req.headers.get("X-Internal-Secret")
    return secret == INTERNAL_SHARED_SECRET

@app.route("/query", methods=["POST"])
def handle_query():
    if not is_internal_call(request):
        return jsonify({"error": "Forbidden"}), 403

    data = request.get_json(silent=True) or {}
    query = data.get("query")
    if not query:
        return jsonify({"error": "Missing 'query'"}), 400

    db_cfg = select_db_for_query(query)
    result, error = execute_query(db_cfg, query)
    if error:
        return jsonify({"error": error}), 500

    return jsonify({
        "strategy": STRATEGY,
        "target_host": db_cfg["host"],
        "rowcount": result["rowcount"],
        "rows": result["rows"],
    }), 200

@app.route("/", methods=["GET"])
def health():
    return jsonify({"status": "proxy-ok", "strategy": STRATEGY}), 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
EOF

chmod +x /opt/proxy/proxy.py

#-----------------------------------
#Use systemd for Gatekeeper
#-----------------------------------
cat << 'EOF' > /etc/systemd/system/proxy.service
[Unit]
Description=Proxy Service
After=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/proxy/proxy.py
WorkingDirectory=/opt/proxy
Restart=always
User=ubuntu
StandardOutput=append:/var/log/proxy.log
StandardError=append:/var/log/proxy.log

[Install]
WantedBy=multi-user.target
EOF

#-----------------------------------
#Activate & start the service
#-----------------------------------
systemctl daemon-reload
systemctl enable proxy
systemctl start proxy