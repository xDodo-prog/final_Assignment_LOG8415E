#!/bin/bash
set -e

DEBIAN_FRONTEND=noninteractive apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y mysql-server

systemctl start mysql
systemctl enable mysql

# Obtenir l'IP privée de cette instance pour générer un server-id unique
PRIVATE_IP=$(hostname -I | awk '{print $1}')
# Convertir le dernier octet de l'IP en server-id (ex: 10.0.3.11 -> server-id=11)
SERVER_ID=$(echo $PRIVATE_IP | awk -F'.' '{print $4}')

# Config MySQL : accepter connexions privées + configuration slave
cat >> /etc/mysql/mysql.conf.d/mysqld.cnf <<EOF

# Replication Configuration (Worker/Slave)
server-id=$SERVER_ID
relay-log=/var/log/mysql/mysql-relay-bin.log
log_bin=/var/log/mysql/mysql-bin.log
binlog_do_db=sakila
read_only=1
bind-address=0.0.0.0
EOF

systemctl restart mysql

# Ajouter utilisateur admin
mysql -uroot <<EOF
CREATE USER 'admin'@'%' IDENTIFIED BY 'Password123';
GRANT ALL PRIVILEGES ON *.* TO 'admin'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

# Attendre que le manager soit prêt (délai simple)
echo "[INFO] Waiting 120 seconds for Manager to be ready..."
sleep 120

# Configurer la réplication depuis le Manager (Master)
MASTER_HOST="10.0.3.10"
MASTER_USER="replicator"
MASTER_PASSWORD="ReplicaPassword123"

mysql -uroot <<EOF
CHANGE MASTER TO
    MASTER_HOST='$MASTER_HOST',
    MASTER_USER='$MASTER_USER',
    MASTER_PASSWORD='$MASTER_PASSWORD',
    MASTER_LOG_FILE='mysql-bin.000001',
    MASTER_LOG_POS=0;

START SLAVE;
EOF

echo "[INFO] Replication configured on Worker (Slave) with server-id=$SERVER_ID"

# Vérifier l'état de la réplication
mysql -uroot -e "SHOW SLAVE STATUS\G" > /var/log/slave-status.log
