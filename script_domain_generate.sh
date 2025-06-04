#!/bin/bash

set -e

# Ask which PHP version will be used
echo "Available PHP versions: 7.4, 8.3, 8.4"
read -p "Enter PHP version to use [default: 8.3]: " PHP_VERSION
PHP_VERSION=${PHP_VERSION:-8.3}

if [[ "$PHP_VERSION" != "7.4" && "$PHP_VERSION" != "8.3" && "$PHP_VERSION" != "8.4" ]]; then
  echo "❌ Invalid PHP version selected. Allowed values: 7.4, 8.3, 8.4"
  exit 1
fi

# Ask for domain(s)
read -p "Enter domain(s) (space-separated, e.g. domain.com www.domain.com): " DOMAINS
DOMAINS=($DOMAINS)

# Validate that each domain doesn't contain http:// or https://
for domain in "${DOMAINS[@]}"; do
  if [[ "$domain" =~ ^https?:// ]]; then
    echo "❌ Do not include http:// or https:// in the domain names."
    exit 1
  fi
done

MAIN_DOMAIN=${DOMAINS[0]}

# Ask for webroot path
read -p "Enter webroot subfolder [default: /public]: " WEBROOT
WEBROOT=${WEBROOT:-/public}

# Ask for Nginx root base
read -p "Enter base path for web root [default: /var/www]: " ROOT_BASE
ROOT_BASE=${ROOT_BASE:-/var/www}
ROOT_PATH="$ROOT_BASE/$MAIN_DOMAIN"
FULL_PATH="$ROOT_PATH$WEBROOT"

# Create folder structure
echo "Creating web root at $FULL_PATH..."
sudo mkdir -p "$FULL_PATH"
sudo chown -R www-data:www-data "$ROOT_PATH"
sudo chmod -R 755 "$ROOT_PATH"

# Create Nginx config
NGINX_CONF="/etc/nginx/sites-available/$MAIN_DOMAIN"

echo "Creating Nginx configuration for $MAIN_DOMAIN..."
sudo tee "$NGINX_CONF" > /dev/null <<EOL
server {
    listen 80;
    listen [::]:80;

    server_name ${DOMAINS[@]};

    root $FULL_PATH;
    index index.php index.html index.htm;

    #access_log /var/log/nginx/${MAIN_DOMAIN}_access.log;
    error_log /var/log/nginx/${MAIN_DOMAIN}_error.log;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Content-Type-Options "nosniff";

    charset utf-8;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    # Prevent Direct Access To Protected Files
    location ~ \.(env|log) {
        deny all;
    }

    # Prevent Direct Access To Protected Folders
    location ~ ^/(^app\$|bootstrap|config|database|overrides|resources|routes|storage|tests|artisan) {
        deny all;
    }

    # Prevent Direct Access To modules/vendor Folders Except Assets
    location ~ ^/(modules|vendor)\/(.*)\.((?!ico|gif|jpg|jpeg|png|js\b|css|less|sass|font|woff|woff2|eot|ttf|svg|xls|xlsx).)*\$ {
        deny all;
    }

    # Pass PHP Scripts To FastCGI Server
    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/var/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOL

# Enable site
echo "Enabling site..."
sudo ln -s "$NGINX_CONF" /etc/nginx/sites-enabled/

# Test and reload Nginx
echo "Testing Nginx configuration..."
sudo nginx -t && sudo service nginx reload

# Issue Let's Encrypt certificates
echo "Issuing Let's Encrypt certificate..."
sudo certbot --nginx -d "${DOMAINS[@]}"

# Ask if user wants to create a MySQL database and user
read -p "Do you want to create a MySQL database and user for this domain? [y/N]: " CREATE_DB
CREATE_DB=${CREATE_DB:-n}

if [[ "$CREATE_DB" =~ ^[Yy]$ ]]; then
  # Ask for MySQL root password
  read -s -p "Enter MySQL root password: " MYSQL_ROOT_PWD
  echo

  # Ask for DB/username (same)
  read -p "Enter the MySQL username (will also be used as database name): " MYSQL_USER

  # Ask for password or generate one
  read -s -p "Enter password for MySQL user (leave empty to auto-generate): " MYSQL_USER_PWD
  echo
  if [ -z "$MYSQL_USER_PWD" ]; then
    MYSQL_USER_PWD=$(openssl rand -base64 12)
    echo "Generated MySQL user password: $MYSQL_USER_PWD"
  fi

  MYSQL_DB="$MYSQL_USER"

  echo "Creating database and user in MySQL..."

  # SQL commands
  SQL="
  CREATE DATABASE IF NOT EXISTS \`$MYSQL_DB\`;
  CREATE USER IF NOT EXISTS '$MYSQL_USER'@'localhost' IDENTIFIED BY '$MYSQL_USER_PWD';
  GRANT ALL PRIVILEGES ON \`$MYSQL_DB\`.* TO '$MYSQL_USER'@'localhost';
  FLUSH PRIVILEGES;
  "

  # Execute SQL
  mysql -u root -p"$MYSQL_ROOT_PWD" -e "$SQL" || {
    echo "❌ Failed to create MySQL user/database. Please check your root password."
    exit 1
  }

  echo
  echo "✅ MySQL database and user created successfully!"
  echo "--------------------------------------------"
  echo "Database: $MYSQL_DB"
  echo "Username: $MYSQL_USER"
  echo "Password: $MYSQL_USER_PWD"
  echo "--------------------------------------------"
  echo "💡 Copy these credentials into your .env file."
fi

echo
echo "✅ Domain $MAIN_DOMAIN configured and ready!"
