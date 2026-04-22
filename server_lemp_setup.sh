#!/bin/bash

set -e

# --- SSH Configuration ---
CURRENT_SSH_PORT=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
CURRENT_SSH_PORT=${CURRENT_SSH_PORT:-22}

CONFIGURE_SSH=false
if [ "$CURRENT_SSH_PORT" != "22" ]; then
  echo "SSH already configured on port $CURRENT_SSH_PORT."
  read -p "Change SSH port? [y/N]: " CHANGE_SSH
  CHANGE_SSH=${CHANGE_SSH:-n}
  if [[ "$CHANGE_SSH" =~ ^[Yy]$ ]]; then
    read -p "Enter new SSH port: " SSH_PORT
    CONFIGURE_SSH=true
  else
    SSH_PORT="$CURRENT_SSH_PORT"
  fi
else
  read -p "Enter SSH port [default: 22]: " SSH_PORT
  SSH_PORT=${SSH_PORT:-22}
  if [ "$SSH_PORT" != "$CURRENT_SSH_PORT" ]; then
    CONFIGURE_SSH=true
  fi
fi

if $CONFIGURE_SSH; then
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
    sudo systemctl restart ssh || sudo systemctl restart sshd
    echo "SSH is now using port $SSH_PORT"
  else
    echo "Invalid port. Keeping SSH on port $CURRENT_SSH_PORT."
    SSH_PORT="$CURRENT_SSH_PORT"
  fi
fi

# --- System Packages ---
echo "Updating package lists..."
sudo apt update

read -p "Run apt upgrade? (skip if recently run) [y/N]: " DO_UPGRADE
DO_UPGRADE=${DO_UPGRADE:-n}
if [[ "$DO_UPGRADE" =~ ^[Yy]$ ]]; then
  sudo apt upgrade -y
fi

echo "Ensuring base tools are installed..."
sudo apt install -y build-essential libpcre3 libpcre3-dev zlib1g-dev libssl-dev \
  libxslt1-dev libgd-dev libgeoip-dev libmaxminddb-dev software-properties-common curl gnupg2 ca-certificates lsb-release unzip

# --- MySQL ---
if command -v mysql &>/dev/null; then
  echo "MySQL already installed, skipping..."
  if [ -f /root/mysql_root_password.txt ]; then
    MYSQL_ROOT_PASSWORD=$(sudo grep -oP '(?<=MySQL root password: ).*' /root/mysql_root_password.txt)
    echo "Root password file found at /root/mysql_root_password.txt"
  else
    echo "WARNING: MySQL is installed but /root/mysql_root_password.txt is missing."
    echo "The root password was set during a previous run. Check your records."
    MYSQL_ROOT_PASSWORD="(unknown)"
  fi
else
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
fi

# --- Nginx ---
if command -v nginx &>/dev/null; then
  echo "Nginx already installed, skipping installation..."
else
  echo "Installing latest stable Nginx..."
  curl https://nginx.org/keys/nginx_signing.key | gpg --dearmor | sudo tee /usr/share/keyrings/nginx-archive-keyring.gpg > /dev/null
  echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" | sudo tee /etc/apt/sources.list.d/nginx.list
  sudo apt update
  sudo apt install -y nginx
fi

echo "Configuring Nginx to support sites-available/sites-enabled..."
sudo mkdir -p /etc/nginx/sites-available
sudo mkdir -p /etc/nginx/sites-enabled

NGINX_MAIN_CONF="/etc/nginx/nginx.conf"

if ! grep -q "include /etc/nginx/sites-enabled/\*;" "$NGINX_MAIN_CONF"; then
  sudo sed -i '/http {/a \    include /etc/nginx/sites-enabled/*;' "$NGINX_MAIN_CONF"
  echo "Added 'include /etc/nginx/sites-enabled/*;' to nginx.conf"
fi

if ! grep -q "client_max_body_size" "$NGINX_MAIN_CONF"; then
  sudo sed -i '/http {/a \\tclient_max_body_size 25M;' "$NGINX_MAIN_CONF"
  echo "Added 'client_max_body_size 25M' to nginx.conf"
fi

sudo nginx -t
if systemctl is-active --quiet nginx; then
  sudo systemctl reload nginx
else
  sudo systemctl start nginx
fi

# --- Certbot ---
if command -v certbot &>/dev/null; then
  echo "Certbot already installed, skipping..."
else
  echo "Installing Certbot..."
  sudo apt install -y certbot python3-certbot-nginx
fi

# --- PHP ---
INSTALLED_PHP_VERSIONS=$(dpkg -l 'php*-fpm' 2>/dev/null | grep '^ii' | sed -E 's/.*php([0-9]+\.[0-9]+)-fpm.*/\1/' | sort -u || true)
PHP_PACKAGES=("cli" "fpm" "common" "mysql" "zip" "gd" "mbstring" "curl" "xml" "bcmath" "intl" "redis" "imagick")
NEED_PHP_INSTALL=false

if [ -n "$INSTALLED_PHP_VERSIONS" ]; then
  echo "PHP already installed: $(echo "$INSTALLED_PHP_VERSIONS" | tr '\n' ' ')"
  read -p "Install additional PHP versions? [y/N]: " ADD_PHP
  ADD_PHP=${ADD_PHP:-n}
  if [[ "$ADD_PHP" =~ ^[Yy]$ ]]; then
    echo "Available PHP versions: 7.4, 8.2, 8.3, 8.4, 8.5"
    read -p "Additional PHP versions to install (space-separated): " PHP_VERSIONS_INPUT
    read -ra PHP_VERSIONS <<< "$PHP_VERSIONS_INPUT"
    NEED_PHP_INSTALL=true
  else
    read -ra PHP_VERSIONS <<< "$INSTALLED_PHP_VERSIONS"
  fi
else
  echo "Available PHP versions: 7.4, 8.2, 8.3, 8.4, 8.5"
  read -p "Which PHP versions to install? (space-separated) [default: 8.3 8.4]: " PHP_VERSIONS_INPUT
  PHP_VERSIONS_INPUT=${PHP_VERSIONS_INPUT:-"8.3 8.4"}
  read -ra PHP_VERSIONS <<< "$PHP_VERSIONS_INPUT"
  NEED_PHP_INSTALL=true
fi

if $NEED_PHP_INSTALL; then
  if [ -z "$INSTALLED_PHP_VERSIONS" ]; then
    sudo add-apt-repository ppa:ondrej/php -y
  fi
  sudo apt update

  for version in "${PHP_VERSIONS[@]}"; do
    echo "Installing PHP $version..."
    PACKAGE_LIST=""
    for package in "${PHP_PACKAGES[@]}"; do
      PACKAGE_LIST+=" php$version-$package"
    done
    sudo apt install -y $PACKAGE_LIST
    sudo phpenmod -v "$version" imagick || true

    PHP_INI="/etc/php/$version/fpm/php.ini"
    if [ -f "$PHP_INI" ]; then
      sudo sed -i 's/^;*upload_max_filesize.*/upload_max_filesize = 25M/' "$PHP_INI"
      sudo sed -i 's/^;*post_max_size.*/post_max_size = 25M/' "$PHP_INI"
    fi

    sudo systemctl restart "php$version-fpm" || true
  done
fi

# Set default PHP CLI version
mapfile -t ALL_PHP_VERSIONS < <(dpkg -l 'php*-fpm' 2>/dev/null | grep '^ii' | sed -E 's/.*php([0-9]+\.[0-9]+)-fpm.*/\1/' | sort -u || true)
if [ ${#ALL_PHP_VERSIONS[@]} -gt 0 ]; then
  DEFAULT_PHP="${ALL_PHP_VERSIONS[0]}"
  read -p "Which PHP version to set as default CLI? [default: $DEFAULT_PHP]: " PHP_CLI_VERSION
  PHP_CLI_VERSION=${PHP_CLI_VERSION:-$DEFAULT_PHP}

  echo "Setting PHP $PHP_CLI_VERSION as default CLI..."
  sudo update-alternatives --install /usr/bin/php php "/usr/bin/php$PHP_CLI_VERSION" 100
  sudo update-alternatives --set php "/usr/bin/php$PHP_CLI_VERSION"
  sudo update-alternatives --set phar "/usr/bin/phar$PHP_CLI_VERSION" || true
  sudo update-alternatives --set phar.phar "/usr/bin/phar.phar$PHP_CLI_VERSION" || true
  sudo update-alternatives --set phpize "/usr/bin/phpize$PHP_CLI_VERSION" || true
  sudo update-alternatives --set php-config "/usr/bin/php-config$PHP_CLI_VERSION" || true
fi

# --- Git ---
if [ "$(git config --global init.defaultBranch 2>/dev/null)" = "main" ]; then
  echo "Git default branch already set to main, skipping..."
else
  echo "Setting default branch for git to main..."
  git config --global init.defaultBranch main
fi

# --- Composer ---
if command -v composer &>/dev/null; then
  echo "Composer already installed ($(composer --version 2>/dev/null | head -1)), skipping..."
else
  echo "Installing Composer..."
  EXPECTED_SIGNATURE="$(curl -s https://composer.github.io/installer.sig)"
  php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
  ACTUAL_SIGNATURE="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"

  if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]; then
    echo "Invalid Composer installer signature"
    rm composer-setup.php
    exit 1
  fi

  php composer-setup.php --quiet
  rm composer-setup.php
  sudo mv composer.phar /usr/local/bin/composer
fi

# --- Node.js ---
if dpkg -l nodejs 2>/dev/null | grep -q '^ii'; then
  echo "Node.js already installed ($(node --version)), skipping..."
else
  echo "Installing Node.js..."
  curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
  sudo apt-get install -y nodejs
fi

# --- Redis (optional) ---
if command -v redis-server &>/dev/null; then
  echo "Redis already installed, skipping..."
else
  read -p "Install Redis server? [y/N]: " INSTALL_REDIS
  INSTALL_REDIS=${INSTALL_REDIS:-n}
  if [[ "$INSTALL_REDIS" =~ ^[Yy]$ ]]; then
    echo "Installing Redis..."
    sudo apt install -y redis-server
    sudo systemctl enable redis-server
    sudo systemctl start redis-server
  fi
fi

# --- Supervisor (optional) ---
if command -v supervisord &>/dev/null; then
  echo "Supervisor already installed, skipping..."
else
  read -p "Install Supervisor for process management? [y/N]: " INSTALL_SUPERVISOR
  INSTALL_SUPERVISOR=${INSTALL_SUPERVISOR:-n}
  if [[ "$INSTALL_SUPERVISOR" =~ ^[Yy]$ ]]; then
    echo "Installing Supervisor..."
    sudo apt install -y supervisor
    sudo systemctl enable supervisor
    sudo systemctl start supervisor
  fi
fi

# --- NVM ---
export NVM_DIR="$HOME/.nvm"
if [ ! -d "$NVM_DIR" ]; then
  echo "Installing NVM..."
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
else
  echo "NVM already installed, skipping..."
fi

[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

if command -v nvm &>/dev/null && nvm ls --no-colors 2>/dev/null | grep -q "lts"; then
  echo "NVM LTS node already installed, skipping..."
else
  nvm install --lts
fi

# --- UFW Firewall ---
echo "Setting up UFW firewall rules..."
sudo ufw allow "$SSH_PORT/tcp"
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable

# --- Summary ---
echo
echo "Setup complete!"
echo "SSH port: $SSH_PORT"
if [ -f /root/mysql_root_password.txt ]; then
  echo "MySQL root password saved at: /root/mysql_root_password.txt"
else
  echo "WARNING: MySQL root password file not found. Check your records."
fi
echo "PHP CLI default: $(php -v 2>/dev/null | head -n 1 || echo 'not installed')"
echo "Nginx: $(nginx -v 2>&1 || echo 'not installed')"
