#!/bin/bash

set -e

# Ask for SSH port
read -p "Enter SSH port [default: 22]: " SSH_PORT
SSH_PORT=${SSH_PORT:-22}

if [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && [[ "$SSH_PORT" -ge 1 && "$SSH_PORT" -le 65535 ]]; then
  echo "Configuring SSH to use port $SSH_PORT..."

  if grep -q "^#*Port " /etc/ssh/sshd_config; then
    sudo sed -i "s/^#*Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
  else
    echo "Port $SSH_PORT" | sudo tee -a /etc/ssh/sshd_config > /dev/null
  fi

  sudo ufw allow "$SSH_PORT/tcp"

  if [ "$SSH_PORT" != "22" ]; then
    sudo ufw delete allow OpenSSH || true
    sudo ufw delete allow 22/tcp || true
  fi

  echo "Restarting SSH..."
  sudo systemctl restart ssh

  echo "✅ SSH is now using port $SSH_PORT"
else
  echo "⚠️ Invalid port. Keeping default SSH port 22."
  SSH_PORT=22
fi

echo "Updating system packages..."
sudo apt update && sudo apt upgrade -y

echo "Installing base tools..."
sudo apt install -y build-essential build-essential libpcre3 libpcre3-dev zlib1g-dev libssl-dev \
libxslt1-dev libgd-dev libgeoip-dev libmaxminddb-dev software-properties-common curl gnupg2 ca-certificates lsb-release unzip

# Install MySQL
echo "Installing MySQL..."
sudo apt install -y mysql-server
MYSQL_ROOT_PASSWORD=$(openssl rand -base64 16)

echo "Configuring MySQL root password..."
sudo mysql <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$MYSQL_ROOT_PASSWORD';
FLUSH PRIVILEGES;
EOF

echo "Saving MySQL root password to /root/mysql_root_password.txt..."
echo "MySQL root password: $MYSQL_ROOT_PASSWORD" | sudo tee /root/mysql_root_password.txt > /dev/null
sudo chmod 600 /root/mysql_root_password.txt

# Install latest stable Nginx from official repo
echo "Installing latest stable Nginx..."
curl https://nginx.org/keys/nginx_signing.key | gpg --dearmor | sudo tee /usr/share/keyrings/nginx-archive-keyring.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" | sudo tee /etc/apt/sources.list.d/nginx.list
sudo apt update
sudo apt install -y nginx

# Ensure Nginx has Ubuntu-style site directories
echo "Configuring Nginx to support sites-available/sites-enabled..."

sudo mkdir -p /etc/nginx/sites-available
sudo mkdir -p /etc/nginx/sites-enabled

# Add include to nginx.conf if not already present
NGINX_MAIN_CONF="/etc/nginx/nginx.conf"
if ! grep -q "include /etc/nginx/sites-enabled/\*;" "$NGINX_MAIN_CONF"; then
  sudo sed -i '/http {/a \    include /etc/nginx/sites-enabled/*;' "$NGINX_MAIN_CONF"
  echo "Added 'include /etc/nginx/sites-enabled/*;' to nginx.conf"
fi

# Install Certbot
echo "Installing Certbot..."
sudo apt install -y certbot python3-certbot-nginx

# Add PHP repository
echo "Adding PHP repositories..."
sudo add-apt-repository ppa:ondrej/php -y
sudo apt update

# Install PHP versions and extensions
PHP_VERSIONS=("7.4" "8.3" "8.4")
PHP_PACKAGES=("cli" "fpm" "common" "mysql" "zip" "gd" "mbstring" "curl" "xml" "bcmath")

for version in "${PHP_VERSIONS[@]}"; do
  echo "Installing PHP $version..."
  PACKAGE_LIST=""
  for package in "${PHP_PACKAGES[@]}"; do
    PACKAGE_LIST+="php$version-$package "
  done
  sudo apt install -y $PACKAGE_LIST
done

# Set PHP 8.3 as default CLI
echo "Setting PHP 8.3 as default CLI..."
sudo update-alternatives --install /usr/bin/php php /usr/bin/php8.3 83
sudo update-alternatives --set php /usr/bin/php8.3

# Set default branch for git
echo "Setting default branch for git to main..."
git config --global init.defaultBranch main

# Install Composer
echo "Installing Composer..."
EXPECTED_SIGNATURE="$(curl -s https://composer.github.io/installer.sig)"
php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
ACTUAL_SIGNATURE="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"

if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]; then
  echo "❌ Invalid Composer installer signature"
  rm composer-setup.php
  exit 1
fi

php composer-setup.php --quiet
rm composer-setup.php
sudo mv composer.phar /usr/local/bin/composer

# Install Node.js and PM2
echo "Installing Node.js and PM2..."
# Add NodeSource repository for Node.js LTS
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
# Install Node.js
sudo apt-get install -y nodejs
# Install PM2 globally
sudo npm install -g pm2
# Set PM2 to start on boot
sudo pm2 startup

# Install NVM + Node.js (as fallback)
echo "Installing NVM as fallback..."
export NVM_DIR="$HOME/.nvm"
if [ ! -d "$NVM_DIR" ]; then
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
fi

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
# Install Node.js LTS using NVM as well (for user-specific versions)
nvm install --lts
# Make sure .bashrc is sourced to have NVM available in the current shell
source ~/.bashrc

# Setup UFW (firewall)
echo "Setting up UFW firewall rules..."
sudo ufw allow "$SSH_PORT/tcp"
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable

echo
echo "✅ Setup complete!"
echo "SSH port is $SSH_PORT"
echo "🔐 MySQL root password: $MYSQL_ROOT_PASSWORD"
echo "🔐 MySQL root password saved at: /root/mysql_root_password.txt security backup"
echo "🌐 PHP CLI default: $(php -v | head -n 1)"
echo "🟢 Nginx: $(nginx -v 2>&1)"
