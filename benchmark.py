import time
import requests
from collections import Counter
import boto3
import os

# -----------------------------
# PARAMÈTRES & ENV
# -----------------------------

ENV_FILE = os.getenv("ENV_FILE", ".env")

def _read_dotenv(path: str) -> dict:
    vals = {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                s = line.strip()
                if not s or s.startswith("#") or "=" not in s:
                    continue
                k, v = s.split("=", 1)
                vals[k.strip()] = v.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return vals

_cfg = {**_read_dotenv(ENV_FILE), **os.environ}

AWS_REGION = _cfg.get("AWS_REGION", "us-east-1")
AWS_ACCESS_KEY_ID = _cfg.get("aws_access_key_id")
AWS_SECRET_ACCESS_KEY = _cfg.get("aws_secret_access_key")
AWS_SESSION_TOKEN = _cfg.get("aws_session_token")

STRATEGIES = ["direct", "random", "latency"]
N_WRITES = 1000
N_READS = 1000
TIMEOUT = 10

# -----------------------------
# GET GATEKEEPER IP
# -----------------------------

def get_gatekeeper_ip():
    session = boto3.Session(
        aws_access_key_id=AWS_ACCESS_KEY_ID or None,
        aws_secret_access_key=AWS_SECRET_ACCESS_KEY or None,
        aws_session_token=AWS_SESSION_TOKEN or None,
        region_name=AWS_REGION,
    )
    ec2 = session.client("ec2")

    r = ec2.describe_instances(
        Filters=[
            {"Name": "tag:Name", "Values": ["Gatekeeper-EC2"]},
            {"Name": "instance-state-name", "Values": ["running"]},
        ]
    )
    for res in r["Reservations"]:
        for inst in res["Instances"]:
            ip = inst.get("PublicIpAddress")
            if ip:
                return ip
    raise RuntimeError("Gatekeeper instance not found or has no public IP")

GATEKEEPER_IP = get_gatekeeper_ip()
GK_URL = f"http://{GATEKEEPER_IP}:8080/query"

# -----------------------------
# Call GATEKEEPER
# -----------------------------

def call_gatekeeper(sql: str, strategy: str | None = None) -> dict:
    payload = {"query": sql}
    if strategy:
        payload["strategy"] = strategy

    r = requests.post(GK_URL, json=payload, timeout=TIMEOUT)
    r.raise_for_status()
    return r.json()

# -----------------------------
# run read and write benchmarks 
# -----------------------------

def run_writes(strategy: str):
    targets = Counter()
    t0 = time.time()

    for i in range(1, N_WRITES + 1):
        last_name = f"BENCH_{strategy}_{i}"
        sql = f"INSERT INTO sakila.actor (first_name, last_name) VALUES ('Bench', '{last_name}')"
        resp = call_gatekeeper(sql, strategy=strategy)
        targets[resp.get("target_host", "unknown")] += 1

    elapsed = time.time() - t0
    return elapsed, targets


def run_reads(strategy: str):
    targets = Counter()
    t0 = time.time()

    for i in range(1, N_READS + 1):
        last_name = f"BENCH_{strategy}_{i}"
        sql = f"SELECT actor_id, first_name, last_name FROM sakila.actor WHERE last_name = '{last_name}'"
        resp = call_gatekeeper(sql, strategy=strategy)
        targets[resp.get("target_host", "unknown")] += 1

    elapsed = time.time() - t0
    return elapsed, targets


def print_counter(title: str, c: Counter):
    total = sum(c.values())
    print(title)
    for k, v in c.most_common():
        pct = (v / total * 100.0) if total else 0.0
        print(f"  - {k}: {v} ({pct:.1f}%)")


def main():
    print(f"Gatekeeper discovered: {GATEKEEPER_IP}")
    print(f"Benchmark endpoint: {GK_URL}")

    for strat in STRATEGIES:
        print("\n" + "=" * 60)
        print(f"STRATEGY = {strat}")

        w_time, w_targets = run_writes(strat)

        # optional: small pause to reduce replication-lag impact on immediate reads
        time.sleep(2)

        r_time, r_targets = run_reads(strat)

        print(f"\nWrites: {N_WRITES} in {w_time:.2f}s  -> {N_WRITES / w_time:.2f} ops/s")
        print_counter("Write target distribution:", w_targets)

        print(f"\nReads : {N_READS} in {r_time:.2f}s  -> {N_READS / r_time:.2f} ops/s")
        print_counter("Read target distribution:", r_targets)

    print("\nDone.")


if __name__ == "__main__":
    main()
