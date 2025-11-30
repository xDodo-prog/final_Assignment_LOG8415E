#!/bin/bash
set -e

DEBIAN_FRONTEND=noninteractive apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y mysql-server wget unzip

systemctl start mysql
systemctl enable mysql

# Config MySQL : accepter connexions privées + activer binary logging pour réplication
cat >> /etc/mysql/mysql.conf.d/mysqld.cnf <<EOF

# Replication Configuration (Manager/Master)
server-id=1
log_bin=/var/log/mysql/mysql-bin.log
binlog_do_db=sakila
bind-address=0.0.0.0
EOF

systemctl restart mysql

# Ajouter utilisateur admin
mysql -uroot <<EOF
CREATE USER 'admin'@'%' IDENTIFIED BY 'Password123';
GRANT ALL PRIVILEGES ON *.* TO 'admin'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

# Créer utilisateur de réplication
mysql -uroot <<EOF
CREATE USER 'replicator'@'%' IDENTIFIED BY 'ReplicaPassword123';
GRANT REPLICATION SLAVE ON *.* TO 'replicator'@'%';
FLUSH PRIVILEGES;
EOF

# Télécharger et installer la base Sakila
cd /tmp
wget https://downloads.mysql.com/docs/sakila-db.zip
unzip sakila-db.zip
cd sakila-db

# Importer Sakila
mysql -uroot < sakila-schema.sql
mysql -uroot < sakila-data.sql

echo "[INFO] Sakila database installed successfully on Manager (Master)"

# Vérifier l'état du master pour la réplication
mysql -uroot -e "SHOW MASTER STATUS\G" > /var/log/master-status.log
