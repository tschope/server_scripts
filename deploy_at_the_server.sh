#!/bin/bash
set -e

echo "🚀 Deployment started ..."

BASE_DIR="/var/www/domain.com"
RELEASES_DIR="$BASE_DIR/releases"
SHARED_DIR="$BASE_DIR/shared"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
NEW_RELEASE="$RELEASES_DIR/$TIMESTAMP"
CURRENT_LINK="$BASE_DIR/current"
REPO_URL="git@github.com:tschope/domain.com.git"

# Create new release folder
mkdir -p "$RELEASES_DIR"

echo "📦 Cloning repo into new release: $NEW_RELEASE"
git clone --branch main --depth 1 "$REPO_URL" "$NEW_RELEASE"

# Link .env from base folder
echo "🔗 Linking .env"
ln -sfn "$BASE_DIR/.env" "$NEW_RELEASE/.env"
ln -sfn "$BASE_DIR/.env" "$NEW_RELEASE/frontend/.env"

# Set the correct PHP version
echo "🧰 Setting PHP version"
sudo update-alternatives --set php /usr/bin/php8.4

# Install Composer Dependencies
echo "📦 Installing composer dependencies"
cd "$NEW_RELEASE"
composer install --no-dev --no-interaction --prefer-dist --optimize-autoloader

# Link shared storage folders (before any permission or artisan steps)
echo "🔗 Linking shared storage"
rm -rf "$NEW_RELEASE/storage"
ln -sfn "$SHARED_DIR/storage" "$NEW_RELEASE/storage"
ln -sfn "$SHARED_DIR/storage/app/public" "$NEW_RELEASE/public/storage"

# Run migrations
echo "🧬 Running migrations"
php artisan migrate --force

# Build frontend
echo "🌐 Building frontend"
cd frontend
npm install
npm run build
cd ..

# Fix folder permissions
echo "🛠️   Fixing permissions"
sudo chown -R www-data:www-data "$SHARED_DIR/storage"
sudo find storage -type d -exec chmod 775 {} \; || true
sudo find storage -type f -exec chmod 664 {} \; || true

# Update current symlink
echo "🔗 Updating current symlink"
ln -sfn "$NEW_RELEASE" "$CURRENT_LINK"

# Restart PM2 www application
cd "$CURRENT_LINK/frontend"
echo "🚀 Restarting PM2"
sudo -u www-data pm2 del application_www
sudo -u www-data pm2 startOrRestart "$BASE_DIR/ecosystem.config.cjs" --only application_www

# Restart Nginx to get the new release
echo "🚀 Restarting Nginx"
sudo systemctl restart nginx

echo "🧹 Cleaning up old releases (keeping last 3)"
cd "$RELEASES_DIR"
sudo ls -1dt */ | tail -n +4 | xargs -I {} sudo rm -rf "{}"

echo "🎉 Deployment complete. Active release: $TIMESTAMP"
