#!/bin/bash

set -e

# Installs Hestia Control Panel on a clean Ubuntu/Debian server.
# The install itself is HestiaCP's official installer — this script only
# collects the flags up front and adds a clean-server guard, so the run is
# unattended instead of a 20-question wizard.
#
# HestiaCP must run on an EMPTY server. Do NOT run this on a box already
# provisioned with server_lemp_setup.sh.
#
# After install, client plans live in Packages (v-add-user-package), and each
# client gets a Hestia login that can create domains, databases and pick a PHP
# version within the limits of their package.

INSTALLER_URL="https://raw.githubusercontent.com/hestiacp/hestiacp/release/install/hst-install.sh"

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must run as root: sudo ./hestia_setup.sh"
  exit 1
fi

# --- OS check ---
. /etc/os-release
case "${ID}-${VERSION_ID}" in
  ubuntu-22.04|ubuntu-24.04|ubuntu-26.04|debian-12|debian-13) ;;
  *)
    echo "Unsupported OS: $PRETTY_NAME"
    echo "HestiaCP supports Ubuntu 22.04/24.04/26.04 and Debian 12/13."
    exit 1
    ;;
esac
echo "Detected $PRETTY_NAME"

MEM_MB=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 ))
echo "RAM: ${MEM_MB} MB"
if [ "$MEM_MB" -lt 2000 ]; then
  echo "Note: under 2 GB the installer disables ClamAV/SpamAssassin on its own."
fi

# --- Clean server check ---
CONFLICTS=""
for pkg in nginx apache2 mysql-server mariadb-server; do
  dpkg -l "$pkg" 2>/dev/null | grep -q "^ii" && CONFLICTS="$CONFLICTS $pkg"
done
command -v php &>/dev/null && CONFLICTS="$CONFLICTS php"

if [ -n "$CONFLICTS" ]; then
  echo
  echo "WARNING: this server is not empty. Found:$CONFLICTS"
  echo "HestiaCP expects a fresh OS and will overwrite an existing LEMP stack."
  read -p "Continue anyway? [y/N]: " FORCE
  [[ "${FORCE:-n}" =~ ^[Yy] ]] || exit 1
fi

# --- Panel settings ---
echo
read -p "Panel hostname (FQDN, e.g. panel.yourdomain.com): " HOSTNAME_FQDN
if ! [[ "$HOSTNAME_FQDN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]; then
  echo "Invalid hostname. It must be a fully qualified domain name."
  exit 1
fi

read -p "Admin email: " ADMIN_EMAIL
if ! [[ "$ADMIN_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[a-zA-Z]{2,}$ ]]; then
  echo "Invalid email."
  exit 1
fi

read -s -p "Admin password (blank = auto-generate): " ADMIN_PASS
echo

read -p "Backend port [default: 8083]: " PANEL_PORT
PANEL_PORT=${PANEL_PORT:-8083}

# --- Stack options ---
echo
read -p "Install Apache behind Nginx? (needed for .htaccess support) [y/N]: " WITH_APACHE
read -p "Install MultiPHP? (lets each client pick their PHP version) [Y/n]: " WITH_MULTIPHP
read -p "Install mail server? (Exim + Dovecot + Roundcube webmail) [Y/n]: " WITH_MAIL
read -p "Enable filesystem quota? (needed for disk limits in plans) [Y/n]: " WITH_QUOTA
read -p "Install Composer + Node.js for clients? [Y/n]: " WITH_DEVTOOLS
if ! [[ "${WITH_DEVTOOLS:-y}" =~ ^[Nn] ]]; then
  read -p "Node.js major version [default: 22]: " NODE_MAJOR
  NODE_MAJOR=${NODE_MAJOR:-22}
  if ! [[ "$NODE_MAJOR" =~ ^[0-9]+$ ]]; then
    echo "Invalid Node.js version."
    exit 1
  fi
fi
read -p "Install Redis with per-client ACL isolation? [y/N]: " WITH_REDIS

ARGS=(
  --hostname "$HOSTNAME_FQDN"
  --email "$ADMIN_EMAIL"
  --port "$PANEL_PORT"
  --lang "pt-br"
  --interactive no
  --force
  --apache      "$([[ "${WITH_APACHE:-n}"   =~ ^[Yy] ]] && echo yes || echo no)"
  --multiphp    "$([[ "${WITH_MULTIPHP:-y}" =~ ^[Nn] ]] && echo no  || echo yes)"
  --quota       "$([[ "${WITH_QUOTA:-y}"    =~ ^[Nn] ]] && echo no  || echo yes)"
)

if [[ "${WITH_MAIL:-y}" =~ ^[Nn] ]]; then
  ARGS+=(--exim no --dovecot no --clamav no --spamassassin no)
else
  # --sieve gives clients server-side filters and vacation autoresponders.
  # ClamAV/SpamAssassin are left unset on purpose: the installer turns them on
  # or off based on available RAM, which is a better call than a fixed default.
  ARGS+=(--exim yes --dovecot yes --sieve yes)

  # Most VPS providers block outbound 25 by default. Worth knowing now and not
  # after a 25-minute install that ends in mail nobody can receive.
  if ! timeout 5 bash -c ': > /dev/tcp/gmail-smtp-in.l.google.com/25' 2>/dev/null; then
    echo
    echo "WARNING: outbound port 25 is blocked on this server."
    echo "Your clients could receive mail but not send any. Ask your provider"
    echo "to unblock it, or plan on relaying through an SMTP service."
    read -p "Continue anyway? [y/N]: " IGNORE_SMTP
    [[ "${IGNORE_SMTP:-n}" =~ ^[Yy] ]] || exit 1
  fi
fi

[ -n "$ADMIN_PASS" ] && ARGS+=(--password "$ADMIN_PASS")

# --- Install ---
echo
echo "Installing dependencies..."
apt update && apt -y upgrade && apt -y install wget curl sudo

TMP_INSTALLER=$(mktemp -d)/hst-install.sh
echo "Downloading HestiaCP installer..."
wget -q --show-progress "$INSTALLER_URL" -O "$TMP_INSTALLER"

echo
echo "Installing HestiaCP (15-25 minutes; the server reboots at the end)..."
bash "$TMP_INSTALLER" "${ARGS[@]}"

# --- Composer and Node.js ---
# Hestia ships neither: Composer is never installed, and Node only comes along
# as a side effect of --webterminal. Clients running Laravel need both, and
# both must live under /usr for jailbash to see them (it binds /usr read-only
# and masks almost nothing, so /usr/bin and /usr/local/bin come through).
if ! [[ "${WITH_DEVTOOLS:-y}" =~ ^[Nn] ]]; then
  if ! command -v node &>/dev/null; then
    echo "Installing Node.js ${NODE_MAJOR}..."
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    apt-get install -y nodejs
  fi

  if ! command -v composer &>/dev/null; then
    echo "Installing Composer..."
    EXPECTED_SUM=$(curl -fsSL https://composer.github.io/installer.sig)
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    if [ "$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');")" != "$EXPECTED_SUM" ]; then
      echo "Composer installer checksum mismatch - skipping Composer."
      rm -f /tmp/composer-setup.php
    else
      php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
      rm -f /tmp/composer-setup.php
    fi
  fi
fi

# --- Redis ---
# Hestia installs neither redis-server nor php-redis. One shared instance
# across all clients is the default and it is wide open: any client with
# jailbash can read every other client's keys, or FLUSHALL the whole box.
# ACLs are what make it safe to resell, so the two are set up together.
if [[ "${WITH_REDIS:-n}" =~ ^[Yy] ]]; then
  echo "Installing Redis..."
  apt-get install -y redis-server

  ACL_FILE="/etc/redis/users.acl"
  REDIS_CONF="/etc/redis/redis.conf"
  ADMIN_PW_FILE="/root/redis_admin_password.txt"

  if [ ! -f "$ADMIN_PW_FILE" ]; then
    REDIS_ADMIN_PASS=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
    printf 'user: hestiaadmin\npassword: %s\n' "$REDIS_ADMIN_PASS" > "$ADMIN_PW_FILE"
    chmod 600 "$ADMIN_PW_FILE"
  else
    REDIS_ADMIN_PASS=$(awk '/^password:/{print $2}' "$ADMIN_PW_FILE")
  fi

  # Redis refuses to start if users are declared in redis.conf *and* an aclfile
  # is set, so every user - including default - has to live in the ACL file.
  if [ ! -f "$ACL_FILE" ]; then
    cat > "$ACL_FILE" <<EOF
user default off
user hestiaadmin on >${REDIS_ADMIN_PASS} ~* &* +@all
EOF
    chown redis:redis "$ACL_FILE"
    chmod 600 "$ACL_FILE"
  fi

  # ponytail: 20% of RAM, floor 128MB. Redis without a cap will OOM-kill MySQL
  # long before it inconveniences the client who filled it. Tune in the include
  # file below if a plan outgrows it.
  REDIS_MAXMEM=$(( MEM_MB / 5 ))
  [ "$REDIS_MAXMEM" -lt 128 ] && REDIS_MAXMEM=128

  cat > /etc/redis/hestia-multitenant.conf <<EOF
# Managed by hestia_setup.sh - see redis_client_add.sh to add client accounts.
aclfile $ACL_FILE
maxmemory ${REDIS_MAXMEM}mb
# noeviction, not allkeys-lru: queued jobs live in Redis too, and evicting
# those loses client work silently. Better to fail the write loudly.
maxmemory-policy noeviction
EOF

  grep -q "hestia-multitenant.conf" "$REDIS_CONF" \
    || echo "include /etc/redis/hestia-multitenant.conf" >> "$REDIS_CONF"

  systemctl restart redis-server
  systemctl enable redis-server

  # php-redis, for every PHP version Hestia installed. Note that v-add-web-php
  # does not include it, so PHP versions added later from the panel need
  # `apt install phpX.Y-redis` by hand.
  for PHP_DIR in /etc/php/*/; do
    PHP_VER=$(basename "$PHP_DIR")
    apt-get install -y "php${PHP_VER}-redis" || echo "No php${PHP_VER}-redis package, skipping."
    systemctl restart "php${PHP_VER}-fpm" 2>/dev/null || true
  done
fi
echo
echo "======================================================"
echo "HestiaCP installed: https://${HOSTNAME_FQDN}:${PANEL_PORT}"
echo
echo "Point ${HOSTNAME_FQDN} at this server's IP so the panel can issue"
echo "its own Let's Encrypt certificate (v-add-letsencrypt-host)."
echo
echo "Next, create client plans before adding clients:"
echo "  Panel -> Packages -> Add Package   (disk, bandwidth, domains, databases)"
echo "  or: v-add-user-package /path/to/package.pkg <name>"
echo
echo "Then one Hestia user per client: Users -> Add User -> pick the package."
echo "Give them SSH Access = jailbash, never bash."
if ! [[ "${WITH_DEVTOOLS:-y}" =~ ^[Nn] ]]; then
  echo
  echo "Composer and Node.js ${NODE_MAJOR} are visible inside jailbash, so clients"
  echo "can run composer install, npm install and php artisan themselves."
  echo "They cannot run systemctl or supervisorctl in there - schedule Laravel's"
  echo "queue:work and schedule:run through Panel -> Cron Jobs instead."
fi
if ! [[ "${WITH_MAIL:-y}" =~ ^[Nn] ]]; then
  echo
  echo "Mail is installed. Before selling mailboxes:"
  echo "  - set the server's rDNS/PTR to ${HOSTNAME_FQDN} in your VPS panel"
  echo "  - per client domain, Hestia generates DKIM; publish the DNS records"
  echo "    it shows under Mail -> <domain> -> DNS records, plus SPF and DMARC"
  echo "  - webmail for clients: https://webmail.<their-domain>"
fi
echo "The firewall is managed by Hestia (Server -> Firewall), not UFW -"
echo "restrict port ${PANEL_PORT} there once you have logged in."
if [[ "${WITH_REDIS:-n}" =~ ^[Yy] ]]; then
  echo
  echo "Redis is installed, capped at ${REDIS_MAXMEM}MB, with the default user"
  echo "disabled. No client can reach it until you give them an account:"
  echo "  ./redis_client_add.sh"
  echo "Admin credentials: ${ADMIN_PW_FILE}"
fi
echo "======================================================"
