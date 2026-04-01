#!/bin/bash

set -e

# Ask which PHP version will be used
echo "Available PHP versions: 7.4, 8.2, 8.3, 8.4, 8.5"
read -p "Enter PHP version to use [default: 8.3]: " PHP_VERSION
PHP_VERSION=${PHP_VERSION:-8.3}

if [[ "$PHP_VERSION" != "7.4" && "$PHP_VERSION" != "8.2" && "$PHP_VERSION" != "8.3" && "$PHP_VERSION" != "8.4" && "$PHP_VERSION" != "8.5" ]]; then
  echo "❌ Invalid PHP version selected. Allowed values: 7.4, 8.2, 8.3, 8.4, 8.5"
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

# Ask if versioning is required
read -p "Enable deploy versioning with timestamped folders? [y/N]: " USE_VERSIONING
USE_VERSIONING=${USE_VERSIONING:-n}

# Ask if this is a Supervisor-managed frontend application
read -p "Is this a Supervisor-managed frontend application? [y/N]: " IS_SUPERVISOR_APP
IS_SUPERVISOR_APP=${IS_SUPERVISOR_APP:-n}

# Ask for app port if needed
if [[ "$IS_SUPERVISOR_APP" =~ ^[Yy]$ ]]; then
  # Suggest next available port
  NEXT_PORT=$(comm -23 <(seq 3000 3100) <(ss -tulpn | grep LISTEN | awk '{print $5}' | sed 's/.*://') | head -n1)
  read -p "Enter application port [default: $NEXT_PORT]: " APP_PORT
  APP_PORT=${APP_PORT:-$NEXT_PORT}

  # Ask if this is a combined Laravel + Frontend setup
  read -p "Is this a combined Laravel API + Frontend setup? [y/N]: " IS_COMBINED
  IS_COMBINED=${IS_COMBINED:-n}

  if [[ "$IS_COMBINED" =~ ^[Yy]$ ]]; then
    read -p "Enter frontend directory relative to root [default: /frontend]: " FRONTEND_DIR
    FRONTEND_DIR=${FRONTEND_DIR:-/frontend}
  fi
fi

# Ask for Nginx root base
read -p "Enter base path for web root [default: /var/www]: " ROOT_BASE
ROOT_BASE=${ROOT_BASE:-/var/www}
ROOT_PATH="$ROOT_BASE/$MAIN_DOMAIN"

if [[ "$USE_VERSIONING" =~ ^[Yy]$ ]]; then
  TIMESTAMP=$(date +%Y%m%d%H%M%S)
  DEPLOYS_PATH="$ROOT_PATH/deploys/$TIMESTAMP"
  CURRENT_PATH="$ROOT_PATH/current"
  FULL_PATH="$CURRENT_PATH/public"

  echo "Creating initial deploy versioned path and symlink for Nginx to avoid syntax error..."
  sudo mkdir -p "$DEPLOYS_PATH/public"
  sudo ln -s "$DEPLOYS_PATH" "$CURRENT_PATH"

  # Ask if rollback script should be created
  read -p "Generate rollback.sh script to switch between versions? [y/N]: " CREATE_ROLLBACK
  CREATE_ROLLBACK=${CREATE_ROLLBACK:-n}

  if [[ "$CREATE_ROLLBACK" =~ ^[Yy]$ ]]; then
    ROLLBACK_SCRIPT="$ROOT_PATH/rollback.sh"
    cat <<'EOF' | sudo tee "$ROLLBACK_SCRIPT" > /dev/null
#!/bin/bash

set -e

# Prompt user to select version from deploys
DEPLOYS_DIR="$(dirname "$0")/deploys"
CURRENT_LINK="$(dirname "$0")/current"

if [ ! -d "$DEPLOYS_DIR" ]; then
  echo "❌ No 'deploys' directory found at $DEPLOYS_DIR"
  exit 1
fi

VERSIONS=($(ls -1 $DEPLOYS_DIR | sort -r))

if [ ${#VERSIONS[@]} -eq 0 ]; then
  echo "❌ No versions found in $DEPLOYS_DIR"
  exit 1
fi

echo "Available versions for rollback:"
select VERSION in "${VERSIONS[@]}"; do
  if [[ -n "$VERSION" ]]; then
    TARGET="$DEPLOYS_DIR/$VERSION"
    if [ -d "$TARGET" ]; then
      echo "Rolling back to: $VERSION"
      rm -f "$CURRENT_LINK"
      ln -s "$TARGET" "$CURRENT_LINK"
      echo "✅ Rolled back to $VERSION"

      echo "🔄 Restarting Nginx..."
      sudo systemctl reload nginx && echo "✅ Nginx reloaded"

      exit 0
    else
      echo "❌ Selected directory does not exist: $TARGET"
    fi
  else
    echo "❌ Invalid selection."
  fi
  break
done
EOF
    sudo chmod +x "$ROLLBACK_SCRIPT"
    echo "✅ Rollback script created at: $ROLLBACK_SCRIPT"
  fi
else
  FULL_PATH="$ROOT_PATH/public"
fi

if [[ "$IS_COMBINED" =~ ^[Yy]$ ]]; then
  FRONTEND_PATH="$ROOT_PATH$FRONTEND_DIR"
fi

# Create folder structure
echo "Creating web root at $FULL_PATH..."
sudo mkdir -p "$FULL_PATH"
sudo chown -R www-data:www-data "$ROOT_PATH"
sudo chmod -R 755 "$ROOT_PATH"

# Create Nginx config
NGINX_CONF="/etc/nginx/sites-available/$MAIN_DOMAIN"

echo "Creating Nginx configuration for $MAIN_DOMAIN..."

# Start writing base config
sudo tee "$NGINX_CONF" > /dev/null <<EOF
server {
    listen 80;
    listen [::]:80;

    server_name ${DOMAINS[@]};

    root $FULL_PATH;
    index index.php index.html index.htm;

    error_log /var/log/nginx/${MAIN_DOMAIN}_error.log;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Content-Type-Options "nosniff";

    charset utf-8;
EOF

# Add PHP handler
sudo tee -a "$NGINX_CONF" > /dev/null <<EOF

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/var/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }
EOF

# Conditional frontend/backend setups
if [[ "$IS_COMBINED" =~ ^[Yy]$ ]]; then
  sudo tee -a "$NGINX_CONF" > /dev/null <<EOF

    location ^~ /api {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ^~ /sanctum/csrf-cookie {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ^~ /storage/ {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ^~ /broadcasting {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location / {
        proxy_pass http://localhost:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_read_timeout 300;
        proxy_connect_timeout 300;
    }
EOF
elif [[ "$IS_SUPERVISOR_APP" =~ ^[Yy]$ ]]; then
  sudo tee -a "$NGINX_CONF" > /dev/null <<EOF

    location / {
        proxy_pass http://localhost:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_read_timeout 300;
        proxy_connect_timeout 300;
        proxy_buffering off;
        chunked_transfer_encoding off;
        proxy_connect_timeout 60s;
        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
    }
EOF
else
  sudo tee -a "$NGINX_CONF" > /dev/null <<EOF

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
EOF
fi

# Append security rules and close
sudo tee -a "$NGINX_CONF" > /dev/null <<'EOF'

    location ~ \.(env|log) {
        deny all;
    }

    location ~ ^/(^app$|bootstrap|config|database|overrides|resources|routes|storage|tests|artisan) {
        deny all;
    }

    location ~ ^/(modules|vendor)/(.*)\.((?!ico|gif|jpg|jpeg|png|js\b|css|less|sass|font|woff|woff2|eot|ttf|svg|xls|xlsx).)*\$ {
        deny all;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

# Enable site
echo "Enabling site..."
sudo ln -s "$NGINX_CONF" /etc/nginx/sites-enabled/

# Test and reload Nginx
echo "Testing Nginx configuration..."
sudo nginx -t && sudo service nginx reload

# Ask if user wants to configure HTTPS now
read -p "Do you want to configure HTTPS (Let's Encrypt) now? [y/N]: " CONFIGURE_HTTPS
CONFIGURE_HTTPS=${CONFIGURE_HTTPS:-n}

if [[ "$CONFIGURE_HTTPS" =~ ^[Yy]$ ]]; then
  # Issue Let's Encrypt certificates
  echo "Issuing Let's Encrypt certificate..."
  sudo certbot --nginx $(printf -- '-d %s ' "${DOMAINS[@]}")
else
  echo "⚠️  HTTPS not configured. Your site is currently HTTP only."
  echo "📝 To configure HTTPS later (after DNS propagation), run:"
  echo "   sudo certbot --nginx $(printf -- '-d %s ' "${DOMAINS[@]}")"
  echo ""
fi

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
