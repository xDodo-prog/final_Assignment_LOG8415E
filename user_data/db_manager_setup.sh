#!/bin/bash
set -euo pipefail

DB_NAME="sakila"
ADMIN_USER="admin"
ADMIN_PASS="Password123"

REPL_USER="replicator"
REPL_PASS="ReplicaPassword123"

DEBIAN_FRONTEND=noninteractive apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y mysql-server wget unzip

systemctl enable mysql
systemctl start mysql

# -----------------------------------
# MySQL Master config: bind + binlog
# -----------------------------------

cat >> /etc/mysql/mysql.conf.d/mysqld.cnf <<EOF

# Replication Configuration (Manager/Master)
server-id=1
log_bin=/var/log/mysql/mysql-bin
binlog_format=ROW
binlog_do_db=${DB_NAME}
bind-address=0.0.0.0
EOF

systemctl restart mysql

# -----------------------------------
# Users
# -----------------------------------
mysql -uroot <<EOF
CREATE USER IF NOT EXISTS '${ADMIN_USER}'@'%' IDENTIFIED BY '${ADMIN_PASS}';
GRANT ALL PRIVILEGES ON *.* TO '${ADMIN_USER}'@'%' WITH GRANT OPTION;

CREATE USER IF NOT EXISTS '${REPL_USER}'@'%' IDENTIFIED BY '${REPL_PASS}';
GRANT REPLICATION SLAVE ON *.* TO '${REPL_USER}'@'%';

FLUSH PRIVILEGES;
EOF

# -----------------------------------
# Install Sakila
# -----------------------------------
cd /tmp
wget -q https://downloads.mysql.com/docs/sakila-db.zip
unzip -o sakila-db.zip
cd sakila-db

mysql -uroot < sakila-schema.sql
mysql -uroot < sakila-data.sql

echo "[INFO] Sakila database installed successfully on Manager (Master)"

# -----------------------------------
# Get Master Status
# -----------------------------------
mysql -uroot -e "SHOW MASTER STATUS\G" > /var/log/master-status.log
echo "[INFO] Master status written to /var/log/master-status.log"
# -----------------------------------
# Done
# -----------------------------------
echo "[INFO] MySQL Master setup complete."