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
    echo "✅ NVM and Node.js installed for deployer."
fi

# Create bare repo
BARE_REPO_PATH="/var/git-bare/${PROJECT_DOMAIN}.git"
echo "Creating bare Git repo at $BARE_REPO_PATH..."
sudo mkdir -p "$BARE_REPO_PATH"
sudo git init --bare "$BARE_REPO_PATH"
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
  mkdir -p "\$WORK_TREE"
else
  WORK_TREE="$WORK_TREE_BASE_FULL"
fi

# Set permissions
sudo chown -R deployer:deployer "\$WORK_TREE"

git --work-tree=\$WORK_TREE --git-dir=$BARE_REPO_PATH checkout $DEPLOY_BRANCH -f

cd \$WORK_TREE
EOL

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
  echo "📦 Installing Node.js version \$NODE_VERSION from package.json..."
  nvm install "\$NODE_VERSION"
  nvm use "\$NODE_VERSION"
else
  echo "📦 No Node.js version specified. Using LTS."
  nvm install --lts
  nvm use --lts
fi

npm install
npm run build
cd "\$WORK_TREE"
EOL
fi

sudo tee -a "$HOOK_PATH" > /dev/null <<'EOL'

# Adjust permissions
echo "Fixing permissions for www-data..."
sudo chown -R www-data:www-data $WORK_TREE

echo "Adjusting folder permissions..."
if [ -d "$WORK_TREE/public" ]; then
  find "$WORK_TREE/public" -type d -exec sudo chmod 755 {} \;
fi

if [ -d "$WORK_TREE/storage" ]; then
  sudo chmod -R ug+rwx "$WORK_TREE/storage"
fi

if [ -d "$WORK_TREE/bootstrap/cache" ]; then
  sudo chmod -R ug+rwx "$WORK_TREE/bootstrap/cache"
fi

# Link to current if versioning
if [ "$USE_VERSIONING" = "y" ] || [ "$USE_VERSIONING" = "Y" ]; then
  echo "Linking current -> $WORK_TREE"
  ln -sfn "$WORK_TREE" "$CURRENT_LINK"
fi

echo "Done!"
EOL

# Make hook executable
sudo chmod +x "$HOOK_PATH"

# Final SSH remote URL
echo
echo "✅ Bare repo created: $BARE_REPO_PATH"
echo "📂 Work tree: $WORK_TREE"
echo "👉 Run this in your local repo to connect:"

if [ "$SSH_PORT" != "22" ]; then
  echo "git remote add live ssh://deployer@${SERVER_HOST}:${SSH_PORT}/var/git-bare/${PROJECT_DOMAIN}.git"
else
  echo "git remote add live ssh://deployer@${SERVER_HOST}/var/git-bare/${PROJECT_DOMAIN}.git"
fi
