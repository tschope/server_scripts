#!/bin/bash

set -e

# Ask for IP/domain of this machine
read -p "Enter the IP or domain of this server (for SSH remote URL): " SERVER_HOST

# Ask for SSH port
read -p "Enter SSH port [default: 22]: " SSH_PORT
SSH_PORT=${SSH_PORT:-22}

# Ask for the domain name (e.g. domain.com)
read -p "Enter the project domain (e.g. domain.com): " PROJECT_DOMAIN

# Ask for base path of the work tree
read -p "Enter base path for work tree [default: /var/www]: " WORK_TREE_BASE
WORK_TREE_BASE=${WORK_TREE_BASE:-/var/www}

# Ask for branch name to deploy
read -p "Which branch should be used for deployment? [default: main]: " DEPLOY_BRANCH
DEPLOY_BRANCH=${DEPLOY_BRANCH:-main}

# Define paths
BARE_REPO_PATH="/var/git-bare/${PROJECT_DOMAIN}.git"
# Define full work tree path
WORK_TREE="${WORK_TREE_BASE}/${PROJECT_DOMAIN}"

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

    # Setup SSH access for deployer from root
    echo "Copying SSH keys from root to deployer..."
    sudo mkdir -p /home/deployer/.ssh
    sudo cp /root/.ssh/authorized_keys /home/deployer/.ssh/
    sudo chown -R deployer:deployer /home/deployer/.ssh
    sudo chmod 700 /home/deployer/.ssh
    sudo chmod 600 /home/deployer/.ssh/authorized_keys
    echo "✅ SSH access configured for deployer user."

    # Install NVM + Node for deployer
    echo "Installing NVM and Node.js for deployer..."
sudo -u deployer bash <<EOF
  export NVM_DIR="\$HOME/.nvm"
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
  source "\$NVM_DIR/nvm.sh"
  nvm install --lts
  echo 'export NVM_DIR="\$HOME/.nvm"' >> ~/.bashrc
  echo '[ -s "\$NVM_DIR/nvm.sh" ] && \. "\$NVM_DIR/nvm.sh"' >> ~/.bashrc
EOF
    echo "✅ NVM and Node.js installed for deployer."

    # Set default branch for git
    echo "Setting default branch for git to main..."
    git config --global init.defaultBranch main
fi

# Create the bare repo
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

# Set correct permissions for worktree
sudo chown -R deployer:deployer "$WORK_TREE"

# Checkout code
git --work-tree=$WORK_TREE --git-dir=$BARE_REPO_PATH checkout $DEPLOY_BRANCH -f

cd $WORK_TREE

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
cd "$WORK_TREE$FRONTEND_PATH"

# Load NVM
export NVM_DIR="/home/deployer/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && \. "\$NVM_DIR/nvm.sh"

# Check if package.json exists
if [ -f "package.json" ]; then
  echo "📦 package.json found. Setting up Node.js and building frontend..."
  
  # Get Node.js version from package.json if specified
  NODE_VERSION=""
  if grep -q '"node":' package.json; then
    NODE_VERSION=$(grep '"node":' package.json | head -n 1 | sed -E 's/.*"node": ?"([^"]+)".*/\1/')
  fi

  # Install and use the specified Node.js version or default to LTS
  if [ -n "$NODE_VERSION" ]; then
    echo "🔧 Installing Node.js version $NODE_VERSION from package.json..."
    nvm install "$NODE_VERSION"
    nvm use "$NODE_VERSION"
  else
    echo "🔧 No Node.js version specified in package.json. Using default LTS."
    nvm install --lts
    nvm use --lts
  fi

  # Install dependencies and build
  echo "📦 Installing dependencies..."
  npm install
  
  # Run build script if it exists in package.json
  if grep -q '"build":' package.json; then
    echo "🔨 Building frontend..."
    npm run build
  else
    echo "ℹ️ No build script found in package.json. Skipping build step."
  fi

  # Auto-restart via PM2 if config exists
  if [ -f "pm2.config.js" ] || [ -f "ecosystem.config.js" ]; then
    echo "🔁 Detected PM2 config file."

    CONFIG_FILE="ecosystem.config.js"
    [ -f "pm2.config.js" ] && CONFIG_FILE="pm2.config.js"

    echo "🚀 Reloading app using PM2 config: $CONFIG_FILE"

    # Try to reload, otherwise start
    pm2 reload $CONFIG_FILE || pm2 start $CONFIG_FILE
  else
    echo "ℹ️ No PM2 config found. Skipping PM2 restart."
  fi
else
  echo "ℹ️ No package.json found. Skipping Node.js and frontend setup."
fi

cd "$WORK_TREE"
EOL
fi

sudo tee -a "$HOOK_PATH" > /dev/null <<'EOL'

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

echo "Done!"
EOL

# Make hook executable
sudo chmod +x "$HOOK_PATH"

# Final output
echo
echo "✅ Bare repo created at: $BARE_REPO_PATH"
echo "📂 Work tree will deploy to: $WORK_TREE"
echo
echo "👉 Now run this command in your local repo:"
echo
if [ "$SSH_PORT" != "22" ]; then
  echo "git remote add live ssh://deployer@${SERVER_HOST}:${SSH_PORT}/var/git-bare/${PROJECT_DOMAIN}.git"
else
  echo "git remote add live ssh://deployer@${SERVER_HOST}/var/git-bare/${PROJECT_DOMAIN}.git"
fi
