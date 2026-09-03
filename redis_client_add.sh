#!/bin/bash

set -e

# Grants one Hestia client a Redis account isolated by ACL: they can only touch
# keys and pub/sub channels under their own prefix, and the commands that would
# let them see or wipe other clients' data are removed.
#
# Run this only for clients whose plan includes Redis. Requires Redis to have
# been installed by hestia_setup.sh, which sets up the ACL file and disables
# the default user.

ACL_FILE="/etc/redis/users.acl"
ADMIN_PW_FILE="/root/redis_admin_password.txt"

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must run as root: sudo ./redis_client_add.sh"
  exit 1
fi

if [ ! -f "$ADMIN_PW_FILE" ]; then
  echo "Redis is not set up for multi-tenant use ($ADMIN_PW_FILE missing)."
  echo "Re-run hestia_setup.sh and answer yes to the Redis question."
  exit 1
fi

REDIS_ADMIN_PASS=$(awk '/^password:/{print $2}' "$ADMIN_PW_FILE")
redis() { redis-cli --user hestiaadmin --pass "$REDIS_ADMIN_PASS" --no-auth-warning "$@"; }

read -p "Hestia username: " CLIENT
if ! [[ "$CLIENT" =~ ^[a-z][a-z0-9_-]{1,29}$ ]]; then
  echo "Invalid username."
  exit 1
fi

if ! id "$CLIENT" &>/dev/null; then
  echo "System user '$CLIENT' does not exist. Create the Hestia user first."
  exit 1
fi

if redis ACL GETUSER "$CLIENT" | grep -q .; then
  echo "Redis user '$CLIENT' already exists."
  read -p "Reset their password? [y/N]: " RESET
  [[ "${RESET:-n}" =~ ^[Yy] ]] || exit 0
fi

CLIENT_PASS=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)

# ~prefix:* limits keys, &prefix:* limits pub/sub channels, and -@dangerous
# drops FLUSHALL, FLUSHDB, KEYS, CONFIG, ACL, MONITOR, CLIENT and DEBUG.
# EVAL/EVALSHA/SCRIPT and PUBLISH/SUBSCRIBE are NOT in @dangerous, so Laravel's
# queue Lua scripts and broadcasting keep working.
redis ACL SETUSER "$CLIENT" on ">${CLIENT_PASS}" "~${CLIENT}:*" "&${CLIENT}:*" \
  "+@all" "-@dangerous" > /dev/null
redis ACL SAVE > /dev/null

echo
echo "======================================================"
echo "Redis account created for $CLIENT."
echo
echo "Add to their .env - the prefix is what the ACL enforces, so if they"
echo "change it Redis will start refusing their writes:"
echo
echo "  REDIS_HOST=127.0.0.1"
echo "  REDIS_PORT=6379"
echo "  REDIS_USERNAME=${CLIENT}"
echo "  REDIS_PASSWORD=${CLIENT_PASS}"
echo "  REDIS_PREFIX=${CLIENT}:"
echo "  CACHE_STORE=redis"
echo "  QUEUE_CONNECTION=redis"
echo
echo "Socket connections do not work from jailbash - only 127.0.0.1 over TCP."
echo
echo "php artisan cache:clear will fail for them: it calls FLUSHDB, which is"
echo "blocked on purpose. Cache::forget() and tagged flushes still work."
echo
echo "Verify the isolation holds:"
echo "  redis-cli --user ${CLIENT} --pass '<pass>' SET ${CLIENT}:ok 1   # OK"
echo "  redis-cli --user ${CLIENT} --pass '<pass>' SET other:x 1        # NOPERM"
echo "  redis-cli --user ${CLIENT} --pass '<pass>' FLUSHALL             # NOPERM"
echo
echo "To revoke: redis-cli --user hestiaadmin --pass \$(awk '/^password:/{print \$2}' $ADMIN_PW_FILE) ACL DELUSER $CLIENT && ... ACL SAVE"
echo "======================================================"
