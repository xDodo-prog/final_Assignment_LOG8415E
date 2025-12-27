#!/bin/bash
set -euo pipefail

MASTER_HOST="10.0.3.10"

DB_NAME="sakila"
ADMIN_USER="admin"
ADMIN_PASS="Password123"

REPL_USER="replicator"
REPL_PASS="ReplicaPassword123"

DEBIAN_FRONTEND=noninteractive apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y mysql-server mysql-client

systemctl enable mysql
systemctl start mysql

# -----------------------------------
# Unique server-id from private IP last octet
# -----------------------------------
PRIVATE_IP=$(hostname -I | awk '{print $1}')
SERVER_ID=$(echo "$PRIVATE_IP" | awk -F'.' '{print $4}')

# -----------------------------------
# MySQL Replica config
# -----------------------------------
cat >> /etc/mysql/mysql.conf.d/mysqld.cnf <<EOF

# Replication Configuration (Worker/Slave)
server-id=${SERVER_ID}
relay-log=/var/log/mysql/mysql-relay-bin
log_bin=/var/log/mysql/mysql-bin
binlog_format=ROW
binlog_do_db=${DB_NAME}
read_only=1
bind-address=0.0.0.0
EOF

systemctl restart mysql

# Admin user locally 
mysql -uroot <<EOF
CREATE USER IF NOT EXISTS '${ADMIN_USER}'@'%' IDENTIFIED BY '${ADMIN_PASS}';
GRANT ALL PRIVILEGES ON *.* TO '${ADMIN_USER}'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

# -----------------------------------
# Wait for master MySQL to be reachable
# -----------------------------------
echo "[INFO] Waiting for MySQL on master (${MASTER_HOST}:3306)..."
for i in {1..120}; do
  if mysql -h "${MASTER_HOST}" -u "${ADMIN_USER}" -p"${ADMIN_PASS}" -e "SELECT 1" >/dev/null 2>&1; then
    echo "[OK] Master MySQL is reachable."
    break
  fi
  sleep 2
  if [ "$i" -eq 120 ]; then
    echo "[ERROR] Master MySQL not reachable after 240s"
    exit 1
  fi
done

# -----------------------------------
# 1) Pull a consistent dump from master that includes correct binlog file/pos
# -----------------------------------
echo "[STEP] Dumping ${DB_NAME} from master with --master-data=2..."
mysqldump \
  -h "${MASTER_HOST}" -u "${ADMIN_USER}" -p"${ADMIN_PASS}" \
  --databases "${DB_NAME}" \
  --single-transaction --master-data=2 --set-gtid-purged=OFF \
  > /tmp/sakila_dump.sql

# Extract binlog coordinates from dump
MASTER_LOG_FILE=$(grep -m1 "MASTER_LOG_FILE" /tmp/sakila_dump.sql | sed -n "s/.*MASTER_LOG_FILE='\([^']*\)'.*/\1/p")
MASTER_LOG_POS=$(grep -m1 "MASTER_LOG_POS"  /tmp/sakila_dump.sql | sed -n "s/.*MASTER_LOG_POS=\([0-9]*\).*/\1/p")

if [ -z "${MASTER_LOG_FILE}" ] || [ -z "${MASTER_LOG_POS}" ]; then
  echo "[ERROR] Could not extract MASTER_LOG_FILE / MASTER_LOG_POS from dump."
  exit 1
fi

echo "[OK] Extracted coordinates: ${MASTER_LOG_FILE}:${MASTER_LOG_POS}"

# -----------------------------------
# 2) Load the dump locally (brings replica to same starting point)
# -----------------------------------
echo "[STEP] Importing dump locally..."
mysql -uroot < /tmp/sakila_dump.sql

# -----------------------------------
# 3) Configure replication using real file/pos (no hardcoding)
# -----------------------------------
echo "[STEP] Configuring replication..."
mysql -uroot <<EOF
STOP SLAVE;
RESET SLAVE ALL;

CHANGE MASTER TO
  MASTER_HOST='${MASTER_HOST}',
  MASTER_USER='${REPL_USER}',
  MASTER_PASSWORD='${REPL_PASS}',
  MASTER_LOG_FILE='${MASTER_LOG_FILE}',
  MASTER_LOG_POS=${MASTER_LOG_POS};

START SLAVE;
EOF

mysql -uroot -e "SHOW SLAVE STATUS\G" > /var/log/slave-status.log
echo "[INFO] Replication configured on Worker with server-id=${SERVER_ID}"
echo "[INFO] Slave status written to /var/log/slave-status.log"
echo "[INFO] Setup complete."
