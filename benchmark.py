import time
import json
import requests
from collections import Counter

GATEKEEPER_IP = "44.201.59.16"
GK_URL = f"http://{GATEKEEPER_IP}:8080/query"
HEADERS = {"Content-Type": "application/json"}

STRATEGIES = ["direct", "random", "latency"]
N_WRITES = 1000
N_READS = 1000

TIMEOUT = 10


def call_gatekeeper(sql: str, strategy: str | None = None) -> dict:
    payload = {"query": sql}
    if strategy:
        payload["strategy"] = strategy

    r = requests.post(GK_URL, headers=HEADERS, data=json.dumps(payload), timeout=TIMEOUT)
    r.raise_for_status()
    return r.json()


def ensure_bench_table():
    call_gatekeeper("""
        CREATE TABLE IF NOT EXISTS sakila.bench_kv (
            id INT AUTO_INCREMENT PRIMARY KEY,
            payload VARCHAR(100) NOT NULL
        )
    """.strip(), strategy="direct")  # strategy doesn't matter for writes; direct is fine


def run_writes(strategy: str):
    targets = Counter()
    t0 = time.time()

    for i in range(1, N_WRITES + 1):
        resp = call_gatekeeper(
            f"INSERT INTO sakila.bench_kv (payload) VALUES ('{strategy}_w_{i}')",
            strategy=strategy,
        )
        targets[resp.get("target_host", "unknown")] += 1

    elapsed = time.time() - t0
    return elapsed, targets


def run_reads(strategy: str):
    targets = Counter()
    t0 = time.time()

    # Read the last N_READS ids; if table is huge, still fine.
    # We will query by id from 1..N_READS (your writes filled them at least once).
    for i in range(1, N_READS + 1):
        resp = call_gatekeeper(
            f"SELECT id, payload FROM sakila.bench_kv WHERE id = {i}",
            strategy=strategy,
        )
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
    print(f"Gatekeeper: {GK_URL}")
    ensure_bench_table()

    for strat in STRATEGIES:
        print("\n" + "=" * 60)
        print(f"STRATEGY = {strat}")

        w_time, w_targets = run_writes(strat)
        r_time, r_targets = run_reads(strat)

        print(f"\nWrites: {N_WRITES} in {w_time:.2f}s  -> {N_WRITES / w_time:.2f} ops/s")
        print_counter("Write target distribution:", w_targets)

        print(f"\nReads : {N_READS} in {r_time:.2f}s  -> {N_READS / r_time:.2f} ops/s")
        print_counter("Read target distribution:", r_targets)

    print("\nDone.")


if __name__ == "__main__":
    main()