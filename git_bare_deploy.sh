#!/bin/bash

set -e

# Ask for server host
read -p "Enter the IP or domain of this server (for SSH remote URL): " SERVER_HOST

# Ask for SSH port
read -p "Enter SSH port [default: 22]: " SSH_PORT
SSH_PORT=${SSH_PORT:-22}

# Ask for domain (repo name)
read -p "Enter the project domain (e.g. domain.com): " PROJECT_DOMAIN

# Ask if versioning is required
read -p "Enable deploy versioning with timestamped folders? [y/N]: " USE_VERSIONING
USE_VERSIONING=${USE_VERSIONING:-n}

# Ask for work tree base
read -p "Enter base path for work tree [default: /var/www]: " WORK_TREE_BASE
WORK_TREE_BASE=${WORK_TREE_BASE:-/var/www}
WORK_TREE_BASE_FULL="$WORK_TREE_BASE/$PROJECT_DOMAIN"

if [[ "$USE_VERSIONING" =~ ^[Yy]$ ]]; then
  DEPLOYS_DIR="$WORK_TREE_BASE_FULL/deploys"
  TIMESTAMP=$(date +%Y%m%d%H%M%S)
  WORK_TREE="$DEPLOYS_DIR/$TIMESTAMP"
  CURRENT_LINK="$WORK_TREE_BASE_FULL/current"
else
  WORK_TREE="$WORK_TREE_BASE_FULL"
fi

# Ask for branch
read -p "Which branch should be used for deployment? [default: main]: " DEPLOY_BRANCH
DEPLOY_BRANCH=${DEPLOY_BRANCH:-main}

# Ask for deploy options
read -p "Run composer install? [Y/n]: " COMPOSER_INSTALL
COMPOSER_INSTALL=${COMPOSER_INSTALL:-y}

read -p "Run php artisan migrate? [Y/n]: " RUN_MIGRATIONS
RUN_MIGRATIONS=${RUN_MIGRATIONS:-y}

read -p "Run npm install and build? [Y/n]: " RUN_NPM
RUN_NPM=${RUN_NPM:-y}

FRONTEND_PATH="/"
if [[ "$RUN_NPM" =~ ^[Yy]$ ]]; then
  read -p "Frontend path relative to root (e.g. / or /frontend) [default: /]: " FRONTEND_PATH
  FRONTEND_PATH=${FRONTEND_PATH:-/}
fi

# Supervisor: frontend Node app
read -p "Use Supervisor for a frontend Node app (e.g. Nuxt)? [y/N]: " USE_SUPERVISOR_FRONTEND
USE_SUPERVISOR_FRONTEND=${USE_SUPERVISOR_FRONTEND:-n}

SUPERVISOR_FRONTEND_PORT=""
FRONTEND_ENV_PATH=""
if [[ "$USE_SUPERVISOR_FRONTEND" =~ ^[Yy]$ ]]; then
  NEXT_PORT=$(comm -23 <(seq 3000 3100) <(ss -tulpn 2>/dev/null | grep LISTEN | awk '{print $5}' | sed 's/.*://') | head -n1)
  NEXT_PORT=${NEXT_PORT:-3000}
  read -p "Enter frontend app port [default: $NEXT_PORT]: " SUPERVISOR_FRONTEND_PORT
  SUPERVISOR_FRONTEND_PORT=${SUPERVISOR_FRONTEND_PORT:-$NEXT_PORT}

  read -p "Frontend .env symlink path relative to root (e.g. /frontend) [leave empty to skip]: " FRONTEND_ENV_PATH
fi

# Laravel Horizon
read -p "Use Laravel Horizon? [y/N]: " USE_HORIZON
USE_HORIZON=${USE_HORIZON:-n}

# Laravel Reverb
read -p "Use Laravel Reverb? [y/N]: " USE_REVERB
USE_REVERB=${USE_REVERB:-n}

REVERB_PORT=""
if [[ "$USE_REVERB" =~ ^[Yy]$ ]]; then
  read -p "Enter Reverb port [default: 24678]: " REVERB_PORT
  REVERB_PORT=${REVERB_PORT:-24678}
fi

# Schedule worker
read -p "Run php artisan schedule:work via Supervisor? [y/N]: " USE_SCHEDULE
USE_SCHEDULE=${USE_SCHEDULE:-n}

# Vendor publish
read -p "Run php artisan vendor:publish? [y/N]: " RUN_VENDOR_PUBLISH
RUN_VENDOR_PUBLISH=${RUN_VENDOR_PUBLISH:-n}

VENDOR_PUBLISH_TAG=""
if [[ "$RUN_VENDOR_PUBLISH" =~ ^[Yy]$ ]]; then
  read -p "Enter tag(s) for vendor:publish (e.g. log-viewer-assets) [leave empty for all]: " VENDOR_PUBLISH_TAG
fi

# Public storage symlink
read -p "Create public/storage symlink (storage:link)? [y/N]: " USE_PUBLIC_STORAGE_LINK
USE_PUBLIC_STORAGE_LINK=${USE_PUBLIC_STORAGE_LINK:-n}

# PHP version for FPM reload
read -p "Which PHP version for php-fpm reload? [default: 8.3]: " PHP_VERSION
PHP_VERSION=${PHP_VERSION:-8.3}

# Sanitize domain for Supervisor program names
SUPERVISOR_NAME="${PROJECT_DOMAIN//[^a-zA-Z0-9]/-}"

# Ensure deployer user exists
if id "deployer" &>/dev/null; then
    echo "User 'deployer' already exists."
else
    echo "Creating user 'deployer'..."
    sudo adduser --disabled-password --gecos "" deployer
    sudo usermod -aG sudo deployer
    echo "deployer ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/deployer > /dev/null

    # Setup SSH access
    sudo mkdir -p /home/deployer/.ssh
    sudo cp /root/.ssh/authorized_keys /home/deployer/.ssh/
    sudo chown -R deployer:deployer /home/deployer/.ssh
    sudo chmod 700 /home/deployer/.ssh
    sudo chmod 600 /home/deployer/.ssh/authorized_keys

    # Install NVM and Node.js
    echo "Installing NVM and Node.js for deployer..."
    sudo -u deployer bash <<EOF
export NVM_DIR="\$HOME/.nvm"
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
source "\$NVM_DIR/nvm.sh"
nvm install --lts
echo 'export NVM_DIR="\$HOME/.nvm"' >> ~/.bashrc
echo '[ -s "\$NVM_DIR/nvm.sh" ] && \\. "\$NVM_DIR/nvm.sh"' >> ~/.bashrc
EOF
    echo "NVM and Node.js installed for deployer."
fi

# Create bare repo
BARE_REPO_PATH="/var/git-bare/${PROJECT_DOMAIN}.git"
echo "Creating bare Git repo at $BARE_REPO_PATH..."
sudo mkdir -p "$BARE_REPO_PATH"
sudo git init --bare "$BARE_REPO_PATH"

# Ensure logs directory exists for ref updates
sudo mkdir -p "$BARE_REPO_PATH/logs"

sudo chown -R deployer:deployer "$BARE_REPO_PATH"

# Create post-receive hook
HOOK_PATH="$BARE_REPO_PATH/hooks/post-receive"
echo "Generating post-receive hook..."
sudo tee "$HOOK_PATH" > /dev/null <<EOL
#!/bin/sh

echo "Start deploy..."

DEPLOYS_DIR="$WORK_TREE_BASE_FULL/deploys"
CURRENT_LINK="$WORK_TREE_BASE_FULL/current"

if [ "$USE_VERSIONING" = "y" ] || [ "$USE_VERSIONING" = "Y" ]; then
  TIMESTAMP=\$(date +%Y%m%d%H%M%S)
  WORK_TREE="\$DEPLOYS_DIR/\$TIMESTAMP"
  sudo mkdir -p "\$WORK_TREE"
else
  WORK_TREE="$WORK_TREE_BASE_FULL"
fi

# Set permissions for deployer to write
sudo chown -R deployer:deployer "\$WORK_TREE"

sudo git --work-tree=\$WORK_TREE --git-dir=$BARE_REPO_PATH checkout $DEPLOY_BRANCH -f
sudo chown -R deployer:deployer "\$WORK_TREE"

cd \$WORK_TREE
EOL

if [[ "$USE_VERSIONING" =~ ^[Yy]$ ]]; then
  sudo tee -a "$HOOK_PATH" > /dev/null <<EOL

# Symlink shared .env for versioned deploy
echo "Linking shared .env..."
sudo ln -sfn "$WORK_TREE_BASE_FULL/.env" "\$WORK_TREE/.env"

# Symlink shared storage for versioned deploy
echo "Linking shared storage..."
if [ ! -d "$WORK_TREE_BASE_FULL/storage" ]; then
  echo "Shared storage not found. Creating from this release..."
  sudo mv "\$WORK_TREE/storage" "$WORK_TREE_BASE_FULL/storage"
else
  sudo rm -rf "\$WORK_TREE/storage"
fi
sudo ln -sfn "$WORK_TREE_BASE_FULL/storage" "\$WORK_TREE/storage"
EOL
fi

# Frontend .env symlink (conditional)
if [[ "$USE_SUPERVISOR_FRONTEND" =~ ^[Yy]$ ]] && [[ -n "$FRONTEND_ENV_PATH" ]]; then
  sudo tee -a "$HOOK_PATH" > /dev/null <<EOL

# Symlink frontend .env
echo "Linking frontend .env..."
sudo ln -sfn "$WORK_TREE_BASE_FULL/.env" "\$WORK_TREE$FRONTEND_ENV_PATH/.env"
EOL
fi

# Public storage symlink (conditional)
if [[ "$USE_PUBLIC_STORAGE_LINK" =~ ^[Yy]$ ]]; then
  sudo tee -a "$HOOK_PATH" > /dev/null <<EOL

# Create public/storage symlink
echo "Linking public/storage..."
sudo ln -sfn "$WORK_TREE_BASE_FULL/storage/app/public" "\$WORK_TREE/public/storage"
EOL
fi

if [[ "$COMPOSER_INSTALL" =~ ^[Yy]$ ]]; then
  sudo tee -a "$HOOK_PATH" > /dev/null <<EOL
echo "Running composer install..."
composer install --no-dev --optimize-autoloader --no-interaction
EOL
fi

if [[ "$RUN_MIGRATIONS" =~ ^[Yy]$ ]]; then
  sudo tee -a "$HOOK_PATH" > /dev/null <<EOL
echo "Running migrations..."
php artisan migrate --force
EOL
fi

if [[ "$RUN_NPM" =~ ^[Yy]$ ]]; then
  sudo tee -a "$HOOK_PATH" > /dev/null <<EOL
echo "Installing JS dependencies and building frontend..."
cd "\$WORK_TREE$FRONTEND_PATH"

export NVM_DIR="/home/deployer/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && \\. "\$NVM_DIR/nvm.sh"

NODE_VERSION=""
if [ -f "package.json" ]; then
  NODE_VERSION=\$(grep '"node":' package.json | head -n 1 | sed -E 's/.*"node": ?"([^"]+)".*/\1/')
fi

if [ -n "\$NODE_VERSION" ]; then
  echo "Installing Node.js version \$NODE_VERSION from package.json..."
  nvm install "\$NODE_VERSION"
  nvm use "\$NODE_VERSION"
else
  echo "No Node.js version specified. Using LTS."
  nvm install --lts
  nvm use --lts
fi

npm install
npm run build
cd "\$WORK_TREE"
EOL
fi

# Vendor publish (conditional)
if [[ "$RUN_VENDOR_PUBLISH" =~ ^[Yy]$ ]]; then
  if [[ -n "$VENDOR_PUBLISH_TAG" ]]; then
    sudo tee -a "$HOOK_PATH" > /dev/null <<EOL

echo "Running vendor:publish --tag=$VENDOR_PUBLISH_TAG..."
php artisan vendor:publish --tag=$VENDOR_PUBLISH_TAG --force
EOL
  else
    sudo tee -a "$HOOK_PATH" > /dev/null <<EOL

echo "Running vendor:publish..."
php artisan vendor:publish --force
EOL
  fi
fi

# Horizon terminate before symlink swap (only with versioning)
if [[ "$USE_HORIZON" =~ ^[Yy]$ ]] && [[ "$USE_VERSIONING" =~ ^[Yy]$ ]]; then
  sudo tee -a "$HOOK_PATH" > /dev/null <<EOL

# Terminate Horizon before switching release
echo "Terminating Horizon..."
php "$WORK_TREE_BASE_FULL/current/artisan" horizon:terminate 2>/dev/null || true
sleep 3
EOL
fi

# Permissions block
sudo tee -a "$HOOK_PATH" > /dev/null <<EOL

# Adjust permissions
echo "Fixing permissions for www-data..."
sudo chown -R www-data:www-data "\$WORK_TREE"

echo "Adjusting folder permissions..."
if [ -d "\$WORK_TREE/public" ]; then
  sudo find "\$WORK_TREE/public" -type d -exec chmod 755 {} \;
fi

if [ -d "\$WORK_TREE/bootstrap/cache" ]; then
  sudo chmod -R ug+rwx "\$WORK_TREE/bootstrap/cache"
fi
EOL

if [[ "$USE_VERSIONING" =~ ^[Yy]$ ]]; then
  sudo tee -a "$HOOK_PATH" > /dev/null <<EOL

# Fix permissions for shared storage
echo "Fixing shared storage permissions..."
sudo chown -R www-data:www-data "$WORK_TREE_BASE_FULL/storage"
sudo find "$WORK_TREE_BASE_FULL/storage" -type d -exec chmod 775 {} \; || true
sudo find "$WORK_TREE_BASE_FULL/storage" -type f -exec chmod 664 {} \; || true

# Link current to this release
echo "Linking current -> \$WORK_TREE"
sudo ln -sfn "\$WORK_TREE" "$WORK_TREE_BASE_FULL/current"
sudo chown -h www-data:www-data "$WORK_TREE_BASE_FULL/current"

# Clean up old releases (keep last 3)
echo "Cleaning up old releases (keeping last 3)..."
cd "$WORK_TREE_BASE_FULL/deploys"
sudo ls -1dt */ | tail -n +4 | xargs -I {} sudo rm -rf "{}"
EOL
else
  sudo tee -a "$HOOK_PATH" > /dev/null <<EOL

if [ -d "\$WORK_TREE/storage" ]; then
  sudo chmod -R ug+rwx "\$WORK_TREE/storage"
fi
EOL
fi

# Supervisor restarts (conditional for each service)
SUPERVISOR_RESTART_LINES=""
if [[ "$USE_SUPERVISOR_FRONTEND" =~ ^[Yy]$ ]]; then
  SUPERVISOR_RESTART_LINES+="sudo supervisorctl restart ${SUPERVISOR_NAME}-nuxt || echo \"Warning: ${SUPERVISOR_NAME}-nuxt restart failed\"\n"
fi
if [[ "$USE_HORIZON" =~ ^[Yy]$ ]]; then
  SUPERVISOR_RESTART_LINES+="sudo supervisorctl restart ${SUPERVISOR_NAME}-horizon || echo \"Warning: ${SUPERVISOR_NAME}-horizon restart failed\"\n"
fi
if [[ "$USE_REVERB" =~ ^[Yy]$ ]]; then
  SUPERVISOR_RESTART_LINES+="sudo supervisorctl restart ${SUPERVISOR_NAME}-reverb || echo \"Warning: ${SUPERVISOR_NAME}-reverb restart failed\"\n"
fi
if [[ "$USE_SCHEDULE" =~ ^[Yy]$ ]]; then
  SUPERVISOR_RESTART_LINES+="sudo supervisorctl restart ${SUPERVISOR_NAME}-schedule || echo \"Warning: ${SUPERVISOR_NAME}-schedule restart failed\"\n"
fi

if [[ -n "$SUPERVISOR_RESTART_LINES" ]]; then
  sudo tee -a "$HOOK_PATH" > /dev/null <<EOL

# Restart Supervisor-managed processes
echo "Restarting Supervisor processes..."
$(echo -e "$SUPERVISOR_RESTART_LINES")
EOL
fi

# PHP-FPM reload
sudo tee -a "$HOOK_PATH" > /dev/null <<EOL

# Reload PHP-FPM
echo "Reloading PHP ${PHP_VERSION} FPM..."
sudo systemctl reload php${PHP_VERSION}-fpm

echo "Done!"
EOL

# Make hook executable
sudo chmod +x "$HOOK_PATH"

# Generate Supervisor config files
echo "Generating Supervisor configuration files..."

# Determine the work directory for Supervisor configs
if [[ "$USE_VERSIONING" =~ ^[Yy]$ ]]; then
  SUPERVISOR_WORK_DIR="$WORK_TREE_BASE_FULL/current"
else
  SUPERVISOR_WORK_DIR="$WORK_TREE_BASE_FULL"
fi

if [[ "$USE_SUPERVISOR_FRONTEND" =~ ^[Yy]$ ]]; then
  NUXT_DIR="$SUPERVISOR_WORK_DIR"
  if [[ -n "$FRONTEND_ENV_PATH" ]]; then
    NUXT_DIR="$SUPERVISOR_WORK_DIR$FRONTEND_ENV_PATH"
  elif [[ "$FRONTEND_PATH" != "/" ]]; then
    NUXT_DIR="$SUPERVISOR_WORK_DIR$FRONTEND_PATH"
  fi

  sudo tee "/etc/supervisor/conf.d/${SUPERVISOR_NAME}-nuxt.conf" > /dev/null <<SCONF
[program:${SUPERVISOR_NAME}-nuxt]
command=/usr/bin/node .output/server/index.mjs
directory=${NUXT_DIR}
environment=HOST="0.0.0.0",PORT="${SUPERVISOR_FRONTEND_PORT}",NODE_ENV="production"
user=www-data
autostart=true
autorestart=true
startsecs=5
startretries=3
stderr_logfile=/var/log/supervisor/${SUPERVISOR_NAME}-nuxt.err.log
stdout_logfile=/var/log/supervisor/${SUPERVISOR_NAME}-nuxt.out.log
SCONF
  echo "Created /etc/supervisor/conf.d/${SUPERVISOR_NAME}-nuxt.conf"
fi

if [[ "$USE_HORIZON" =~ ^[Yy]$ ]]; then
  sudo tee "/etc/supervisor/conf.d/${SUPERVISOR_NAME}-horizon.conf" > /dev/null <<SCONF
[program:${SUPERVISOR_NAME}-horizon]
command=php artisan horizon
directory=${SUPERVISOR_WORK_DIR}
user=www-data
autostart=true
autorestart=true
startsecs=5
startretries=3
stopwaitsecs=30
stderr_logfile=/var/log/supervisor/${SUPERVISOR_NAME}-horizon.err.log
stdout_logfile=/var/log/supervisor/${SUPERVISOR_NAME}-horizon.out.log
SCONF
  echo "Created /etc/supervisor/conf.d/${SUPERVISOR_NAME}-horizon.conf"
fi

if [[ "$USE_REVERB" =~ ^[Yy]$ ]]; then
  sudo tee "/etc/supervisor/conf.d/${SUPERVISOR_NAME}-reverb.conf" > /dev/null <<SCONF
[program:${SUPERVISOR_NAME}-reverb]
command=php artisan reverb:start --port=${REVERB_PORT}
directory=${SUPERVISOR_WORK_DIR}
user=www-data
autostart=true
autorestart=true
startsecs=5
startretries=3
stderr_logfile=/var/log/supervisor/${SUPERVISOR_NAME}-reverb.err.log
stdout_logfile=/var/log/supervisor/${SUPERVISOR_NAME}-reverb.out.log
SCONF
  echo "Created /etc/supervisor/conf.d/${SUPERVISOR_NAME}-reverb.conf"
fi

if [[ "$USE_SCHEDULE" =~ ^[Yy]$ ]]; then
  sudo tee "/etc/supervisor/conf.d/${SUPERVISOR_NAME}-schedule.conf" > /dev/null <<SCONF
[program:${SUPERVISOR_NAME}-schedule]
command=php artisan schedule:work
directory=${SUPERVISOR_WORK_DIR}
user=www-data
autostart=true
autorestart=true
startsecs=5
startretries=3
stderr_logfile=/var/log/supervisor/${SUPERVISOR_NAME}-schedule.err.log
stdout_logfile=/var/log/supervisor/${SUPERVISOR_NAME}-schedule.out.log
SCONF
  echo "Created /etc/supervisor/conf.d/${SUPERVISOR_NAME}-schedule.conf"
fi

# Reload Supervisor if any configs were generated
if [[ "$USE_SUPERVISOR_FRONTEND" =~ ^[Yy]$ ]] || [[ "$USE_HORIZON" =~ ^[Yy]$ ]] || \
   [[ "$USE_REVERB" =~ ^[Yy]$ ]] || [[ "$USE_SCHEDULE" =~ ^[Yy]$ ]]; then
  echo "Reloading Supervisor..."
  sudo supervisorctl reread
  sudo supervisorctl update
fi

# Final SSH remote URL
echo
echo "Bare repo created: $BARE_REPO_PATH"
echo "Work tree: $WORK_TREE"
echo "Run this in your local repo to connect:"

if [ "$SSH_PORT" != "22" ]; then
  echo "git remote add live ssh://deployer@${SERVER_HOST}:${SSH_PORT}/var/git-bare/${PROJECT_DOMAIN}.git"
else
  echo "git remote add live ssh://deployer@${SERVER_HOST}/var/git-bare/${PROJECT_DOMAIN}.git"
fi
