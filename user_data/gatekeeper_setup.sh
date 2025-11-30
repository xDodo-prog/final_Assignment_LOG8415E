#!/bin/bash
set -e #stop if it fail

#-----------------------------------
# Update & Python installation
#-----------------------------------

apt-get update -y
apt-get install -y python3 python3-pip

pip3 install flask requests mysql-connector-python

#-----------------------------------
#Create the folder gatekeeper in opt
#-----------------------------------

mkdir -p /opt/gatekeeper
cd /opt/gatekeeper

#-----------------------------------
#Python script for the gatekeeper
#-----------------------------------

cat << 'EOF' > /opt/gatekeeper/gatekeeper.py
#!/usr/bin/env python3
from flask import Flask, request, jsonify
import requests
import os
import re

app = Flask(__name__)

PROXY_URL = os.getenv("PROXY_URL", "http://10.0.2.15:5000/query")
GATEKEEPER_API_KEY = os.getenv("GATEKEEPER_API_KEY", "final-assignment")
INTERNAL_SHARED_SECRET = os.getenv("INTERNAL_SHARED_SECRET", "db-shared-secret")

DANGEROUS_PATTERNS = [
    r"\bDROP\s+TABLE\b",
    r"\bDROP\s+DATABASE\b",
    r"\bTRUNCATE\s+TABLE\b",
    r"\bSHUTDOWN\b",
    r"\bALTER\s+USER\b",
    r"\bGRANT\s+ALL\b",
]

def is_authorized(req) -> bool:
    api_key = req.headers.get("X-API-KEY")
    return api_key == GATEKEEPER_API_KEY

def is_query_safe(query: str) -> bool:
    if not query or not isinstance(query,str):
        return False
    q = query.strip().upper()
    if ";" in q[:-1]:
        return False
    for pat in DANGEROUS_PATTERNS:
        if re.search(pat, q, flags=re.IGNORECASE):
            return False
    if re.match(r"^DELETE\s+FROM\s+\w+\s*;?$", q, flags=re.IGNORECASE):
        return False
    return True

@app.route("/query", methods=["POST"])
def handle_query():
    if not is_authorized(request):
        return jsonify({"error": "Unauthorized"}), 401

    data = request.get_json(silent=True) or {}
    query = data.get("query")
    if not query:
        return jsonify({"error": "Missing 'query'"}), 400

    if not is_query_safe(query):
        return jsonify({"error": "Query rejected by gatekeeper"}), 400

    try:
        headers = {"X-Internal-Secret": INTERNAL_SHARED_SECRET}
        resp = requests.post(PROXY_URL, json={"query": query}, headers=headers, timeout=10)
        return jsonify(resp.json()), resp.status_code
    except Exception as e:
        return jsonify({"error": f"Proxy unreachable: {e}"}), 502

@app.route("/", methods=["GET"])
def health():
    return jsonify({"status": "gatekeeper-ok"}), 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80)
EOF

chmod +x /opt/gatekeeper/gatekeeper.py

#-----------------------------------
#Use systemd for Gatekeeper
#-----------------------------------
cat << 'EOF' > /etc/systemd/system/gatekeeper.service
[Unit]
Description=Gatekeeper API  Service
After=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/gatekeeper/gatekeeper.py
WorkingDirectory=/opt/gatekeeper
Restart=always
User=ubuntu
StandardOutput=append:/var/log/gatekeeper.log
StandardError=append:/var/log/gatekeeper.log

[Install]
WantedBy=multi-user.target
EOF

#-----------------------------------
#Activate & start the service
#-----------------------------------
systemctl daemon-reload
systemctl enable gatekeeper
systemctl start gatekeeper
