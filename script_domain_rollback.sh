#!/bin/bash

# Rollback script for script_domain_generate.sh + git_bare_deploy.sh
# Removes Nginx config, web root, git bare repo, Supervisor configs,
# Let's Encrypt cert, and optionally MySQL DB/user.
# Use this to fully tear down a domain (e.g. to reconnect a different Git remote).

set -e

echo "⚠️  This script will remove resources created by script_domain_generate.sh and git_bare_deploy.sh."
echo "    Run it ONLY if you want to fully undo a domain provisioning."
echo

# Ask for the main domain (the first domain passed to the generator)
read -p "Enter the MAIN domain to rollback (e.g. domain.com): " MAIN_DOMAIN
if [ -z "$MAIN_DOMAIN" ]; then
  echo "❌ Domain is required."
  exit 1
fi

if [[ "$MAIN_DOMAIN" =~ ^https?:// ]]; then
  echo "❌ Do not include http:// or https:// in the domain."
  exit 1
fi

# Ask for web root base (must match what was used in generate)
read -p "Enter base path for web root [default: /var/www]: " ROOT_BASE
ROOT_BASE=${ROOT_BASE:-/var/www}
ROOT_PATH="$ROOT_BASE/$MAIN_DOMAIN"

NGINX_AVAILABLE="/etc/nginx/sites-available/$MAIN_DOMAIN"
NGINX_ENABLED="/etc/nginx/sites-enabled/$MAIN_DOMAIN"
NGINX_ERROR_LOG="/var/log/nginx/${MAIN_DOMAIN}_error.log"
LE_LIVE="/etc/letsencrypt/live/$MAIN_DOMAIN"
LE_ARCHIVE="/etc/letsencrypt/archive/$MAIN_DOMAIN"
LE_RENEWAL="/etc/letsencrypt/renewal/${MAIN_DOMAIN}.conf"
BARE_REPO_PATH="/var/git-bare/${MAIN_DOMAIN}.git"
SUPERVISOR_NAME="${MAIN_DOMAIN//[^a-zA-Z0-9]/-}"
SUPERVISOR_CONFS=(/etc/supervisor/conf.d/${SUPERVISOR_NAME}-*.conf)

echo
echo "🔎 The following resources will be inspected and removed if present:"
echo "    Web root:         $ROOT_PATH"
echo "    Nginx available:  $NGINX_AVAILABLE"
echo "    Nginx enabled:    $NGINX_ENABLED"
echo "    Nginx error log:  $NGINX_ERROR_LOG"
echo "    Let's Encrypt:    $LE_LIVE, $LE_ARCHIVE, $LE_RENEWAL"
echo "    Git bare repo:    $BARE_REPO_PATH"
echo "    Supervisor confs: /etc/supervisor/conf.d/${SUPERVISOR_NAME}-*.conf"
echo "    MySQL DB/user:    (you will be asked separately)"
echo

read -p "Proceed with rollback? [y/N]: " CONFIRM
CONFIRM=${CONFIRM:-n}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# --- Nginx ---
echo
echo "=== Nginx ==="
if [ -L "$NGINX_ENABLED" ] || [ -e "$NGINX_ENABLED" ]; then
  echo "Removing symlink: $NGINX_ENABLED"
  sudo rm -f "$NGINX_ENABLED"
else
  echo "ℹ️  No enabled symlink at $NGINX_ENABLED"
fi

if [ -f "$NGINX_AVAILABLE" ]; then
  echo "Removing config: $NGINX_AVAILABLE"
  sudo rm -f "$NGINX_AVAILABLE"
else
  echo "ℹ️  No config at $NGINX_AVAILABLE"
fi

if [ -f "$NGINX_ERROR_LOG" ]; then
  read -p "Remove Nginx error log $NGINX_ERROR_LOG? [y/N]: " RM_LOG
  RM_LOG=${RM_LOG:-n}
  if [[ "$RM_LOG" =~ ^[Yy]$ ]]; then
    sudo rm -f "$NGINX_ERROR_LOG"
    echo "Removed $NGINX_ERROR_LOG"
  fi
fi

# Test and reload nginx only if a config still validates
if sudo nginx -t 2>/dev/null; then
  echo "Reloading Nginx..."
  sudo service nginx reload || echo "⚠️  Could not reload Nginx."
else
  echo "⚠️  Nginx config test failed — skipping reload. Fix manually and run 'sudo nginx -t'."
fi

# --- Web root ---
echo
echo "=== Web root ==="
if [ -d "$ROOT_PATH" ] || [ -L "$ROOT_PATH" ]; then
  echo "About to delete: $ROOT_PATH"
  echo "    Contents preview:"
  sudo ls -la "$ROOT_PATH" 2>/dev/null | head -n 20 || true
  read -p "Confirm deletion of $ROOT_PATH? [y/N]: " RM_ROOT
  RM_ROOT=${RM_ROOT:-n}
  if [[ "$RM_ROOT" =~ ^[Yy]$ ]]; then
    sudo rm -rf "$ROOT_PATH"
    echo "✅ Removed $ROOT_PATH"
  else
    echo "Skipped web root deletion."
  fi
else
  echo "ℹ️  No web root at $ROOT_PATH"
fi

# --- Supervisor ---
echo
echo "=== Supervisor ==="
FOUND_CONFS=()
for conf in "${SUPERVISOR_CONFS[@]}"; do
  [ -f "$conf" ] && FOUND_CONFS+=("$conf")
done

if [ ${#FOUND_CONFS[@]} -gt 0 ]; then
  echo "Found Supervisor configs:"
  printf '    %s\n' "${FOUND_CONFS[@]}"
  read -p "Stop and remove these Supervisor programs? [y/N]: " RM_SUPERVISOR
  RM_SUPERVISOR=${RM_SUPERVISOR:-n}
  if [[ "$RM_SUPERVISOR" =~ ^[Yy]$ ]]; then
    for conf in "${FOUND_CONFS[@]}"; do
      PROGRAM_NAME=$(basename "$conf" .conf)
      sudo supervisorctl stop "$PROGRAM_NAME" 2>/dev/null || true
      sudo rm -f "$conf"
      echo "✅ Removed $conf"
    done
    sudo supervisorctl reread
    sudo supervisorctl update
  else
    echo "Skipped Supervisor cleanup."
  fi
else
  echo "ℹ️  No Supervisor configs matching ${SUPERVISOR_NAME}-*.conf"
fi

# --- Git bare repo ---
echo
echo "=== Git bare repo ==="
if [ -d "$BARE_REPO_PATH" ]; then
  read -p "Delete bare Git repo at $BARE_REPO_PATH? [y/N]: " RM_BARE
  RM_BARE=${RM_BARE:-n}
  if [[ "$RM_BARE" =~ ^[Yy]$ ]]; then
    sudo rm -rf "$BARE_REPO_PATH"
    echo "✅ Removed $BARE_REPO_PATH"
  else
    echo "Skipped git bare repo deletion."
  fi
else
  echo "ℹ️  No git bare repo at $BARE_REPO_PATH"
fi

# --- Let's Encrypt ---
echo
echo "=== Let's Encrypt ==="
if [ -d "$LE_LIVE" ] || [ -d "$LE_ARCHIVE" ] || [ -f "$LE_RENEWAL" ]; then
  read -p "Revoke and delete Let's Encrypt certificate for $MAIN_DOMAIN? [y/N]: " RM_CERT
  RM_CERT=${RM_CERT:-n}
  if [[ "$RM_CERT" =~ ^[Yy]$ ]]; then
    if command -v certbot >/dev/null 2>&1; then
      # certbot delete handles live/, archive/, and renewal/ atomically
      sudo certbot delete --cert-name "$MAIN_DOMAIN" --non-interactive || {
        echo "⚠️  certbot delete failed — falling back to manual removal."
        sudo rm -rf "$LE_LIVE" "$LE_ARCHIVE"
        sudo rm -f "$LE_RENEWAL"
      }
      echo "✅ Certificate removed."
    else
      echo "certbot not installed — removing files manually."
      sudo rm -rf "$LE_LIVE" "$LE_ARCHIVE"
      sudo rm -f "$LE_RENEWAL"
    fi
  else
    echo "Skipped certificate removal."
  fi
else
  echo "ℹ️  No Let's Encrypt artifacts for $MAIN_DOMAIN."
fi

# --- MySQL ---
echo
echo "=== MySQL ==="
read -p "Remove a MySQL database and user created for this domain? [y/N]: " RM_DB
RM_DB=${RM_DB:-n}
if [[ "$RM_DB" =~ ^[Yy]$ ]]; then
  read -s -p "Enter MySQL root password: " MYSQL_ROOT_PWD
  echo
  read -p "Enter the MySQL username to drop (also used as database name): " MYSQL_USER

  if [ -z "$MYSQL_USER" ]; then
    echo "❌ Username is required to drop. Skipping MySQL cleanup."
  else
    MYSQL_DB="$MYSQL_USER"

    # Probe credentials first so we don't half-apply changes.
    if ! mysql -u root -p"$MYSQL_ROOT_PWD" -e "SELECT 1;" >/dev/null 2>&1; then
      echo "❌ Could not authenticate to MySQL. Skipping MySQL cleanup."
    else
      SQL="
      DROP DATABASE IF EXISTS \`$MYSQL_DB\`;
      DROP USER IF EXISTS '$MYSQL_USER'@'localhost';
      FLUSH PRIVILEGES;
      "
      if mysql -u root -p"$MYSQL_ROOT_PWD" -e "$SQL"; then
        echo "✅ Dropped database \`$MYSQL_DB\` and user '$MYSQL_USER'@'localhost'."
      else
        echo "❌ Failed to drop MySQL resources."
      fi
    fi
  fi
else
  echo "Skipped MySQL cleanup."
fi

echo
echo "✅ Rollback finished for $MAIN_DOMAIN."
echo "💡 You can now re-run ./script_domain_generate.sh and ./git_bare_deploy.sh from scratch"
echo "   (e.g. to connect a different Git remote/repo)."
