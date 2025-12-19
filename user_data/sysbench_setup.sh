#!/bin/bash
set -euo pipefail

echo "[BENCH] starting sysbench benchmark setup"

MASTER_HOST="10.0.3.10"
WORKER1="10.0.3.11"
WORKER2="10.0.3.12"
DB_USER="admin"
DB_PASS="Password123"
DB_NAME="sakila"

THREADS=16
TIME=60
TABLES=4
TABLE_SIZE=100000

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y sysbench mysql-client

OUT="/var/log/sysbench_results.txt"
echo "==== SYSBENCH RESULTS $(date -Is) ====" | tee -a "$OUT"

echo "[BENCH] testing mysql connectivity..." | tee -a "$OUT"
mysql -h "$MASTER_HOST" -u "$DB_USER" -p"$DB_PASS" -e "SELECT 1;" "$DB_NAME" | tee -a "$OUT"

# 1) PREPARE (tables sbtest*) on MASTER only
echo "---- PREPARE (master) ----" | tee -a "$OUT"
sysbench \
  --db-driver=mysql \
  --mysql-host="$MASTER_HOST" \
  --mysql-user="$DB_USER" \
  --mysql-password="$DB_PASS" \
  --mysql-db="$DB_NAME" \
  --tables="$TABLES" \
  --table-size="$TABLE_SIZE" \
  oltp_read_write prepare | tee -a "$OUT"

# 2) READ/WRITE on MASTER
echo "---- RUN oltp_read_write (master) ----" | tee -a "$OUT"
sysbench \
  --db-driver=mysql \
  --mysql-host="$MASTER_HOST" \
  --mysql-user="$DB_USER" \
  --mysql-password="$DB_PASS" \
  --mysql-db="$DB_NAME" \
  --tables="$TABLES" \
  --threads="$THREADS" \
  --time="$TIME" \
  oltp_read_write run | tee -a "$OUT"

# 3) READ ONLY on WORKERS
for W in "$WORKER1" "$WORKER2"; do
  echo "---- RUN oltp_read_only (worker $W) ----" | tee -a "$OUT"
  sysbench \
    --db-driver=mysql \
    --mysql-host="$W" \
    --mysql-user="$DB_USER" \
    --mysql-password="$DB_PASS" \
    --mysql-db="$DB_NAME" \
    --tables="$TABLES" \
    --threads="$THREADS" \
    --time="$TIME" \
    oltp_read_only run | tee -a "$OUT"
done

# 4) CLEANUP on MASTER
echo "---- CLEANUP (master) ----" | tee -a "$OUT"
sysbench \
  --db-driver=mysql \
  --mysql-host="$MASTER_HOST" \
  --mysql-user="$DB_USER" \
  --mysql-password="$DB_PASS" \
  --mysql-db="$DB_NAME" \
  --tables="$TABLES" \
  oltp_read_write cleanup | tee -a "$OUT"

echo "[BENCH] finished. Results saved to $OUT"
