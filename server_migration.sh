#!/usr/bin/env bash

# === Configuration ===
OLD_SERVER="root@127.0.0.1"
SSH_PORT=22
MYSQL_DUMP_PATH="/root/all_databases.sql"
TEAMSPEAK_DIR="/opt/teamspeak"

echo "🚀 Starting full server migration..."

# === Ensure local directories exist ===
mkdir -p /var/www /var/git-bare /etc/nginx /etc/letsencrypt

# === Transfer web files and Nginx/SSL configs ===
echo "📂 Transferring website files and Nginx configurations..."
rsync -avz -e "ssh -p $SSH_PORT" $OLD_SERVER:/var/www/ /var/www/
rsync -avz -e "ssh -p $SSH_PORT" $OLD_SERVER:/var/git-bare/ /var/git-bare/
rsync -avz -e "ssh -p $SSH_PORT" $OLD_SERVER:/etc/nginx/ /etc/nginx/
rsync -avz -e "ssh -p $SSH_PORT" $OLD_SERVER:/etc/letsencrypt/ /etc/letsencrypt/

# === Create MySQL dump on the old server ===
echo "💾 Dumping MySQL databases on the old server..."
ssh -p $SSH_PORT $OLD_SERVER "mysqldump -u root -p --all-databases --routines --events --triggers > $MYSQL_DUMP_PATH"

# === Transfer MySQL dump file ===
echo "📥 Transferring MySQL dump to the new server..."
rsync -avz -e "ssh -p $SSH_PORT" $OLD_SERVER:$MYSQL_DUMP_PATH $MYSQL_DUMP_PATH

# === Import MySQL dump into the new server ===
echo "📤 Importing MySQL databases..."
mysql -u root -p < $MYSQL_DUMP_PATH

# === Stop and transfer TeamSpeak server ===
echo "🎙️ Transferring TeamSpeak server..."
ssh -p $SSH_PORT $OLD_SERVER "$TEAMSPEAK_DIR/ts3server_startscript.sh stop"
rsync -avz -e "ssh -p $SSH_PORT" $OLD_SERVER:$TEAMSPEAK_DIR $TEAMSPEAK_DIR

# === Create the teamspeak user if it doesn't exist ===
echo "👤 Creating 'teamspeak' user if not present..."
id -u teamspeak &>/dev/null || adduser --disabled-login --gecos "" teamspeak
chown -R teamspeak:teamspeak $TEAMSPEAK_DIR

# === Open required ports for TeamSpeak ===
echo "🔓 Allowing TeamSpeak ports through the firewall..."
ufw allow 9987/udp
ufw allow 10011/tcp
ufw allow 30033/tcp

echo "✅ Migration complete! You can now start TeamSpeak and test services."
