# Server Setup and Deployment Scripts

This repository contains shell scripts for setting up and managing a LEMP (Linux, Nginx, MySQL, PHP) server environment and deploying web applications.

## Scripts Overview

1. **server_lemp_setup.sh** - Initial server setup with LEMP stack
2. **script_domain_generate.sh** - Configures Nginx for new domains
3. **git_bare_deploy.sh** - Sets up Git-based deployment with Supervisor process management
4. **deploy_at_the_server.sh** - Zero-downtime deploy script with symlink swap
5. **server_migration.sh** - rsync-based migration from an old server

## Prerequisites

- Ubuntu/Debian-based Linux server
- Sudo/root access
- Basic knowledge of Linux command line

## 1. server_lemp_setup.sh

This script performs the initial server setup, including:
- SSH security configuration
- Firewall setup (UFW)
- LEMP stack installation (Linux, Nginx, MySQL, PHP)
- Composer, Node.js, and Supervisor installation

### Usage

```bash
chmod +x server_lemp_setup.sh
sudo ./server_lemp_setup.sh
```

### What it does:
1. Configures SSH port (default: 22)
2. Updates system packages
3. Installs and configures:
   - Nginx web server
   - MySQL database server
   - PHP 7.4, 8.2, 8.3, 8.4, 8.5 with common extensions
   - Composer (PHP package manager)
   - Node.js (via NodeSource + NVM as fallback)
   - Supervisor (process manager)
   - Certbot (Let's Encrypt)
4. Sets up basic firewall rules (SSH, HTTP, HTTPS)
5. Sets PHP 8.3 as default CLI

**Note:** The MySQL root password will be saved to `/root/mysql_root_password.txt`.

## 2. script_domain_generate.sh

This script helps you set up a new domain with Nginx, including PHP-FPM configuration, optional Supervisor proxy, and SSL certificates using Let's Encrypt.

### Usage

```bash
chmod +x script_domain_generate.sh
sudo ./script_domain_generate.sh
```

### What it does:
1. Asks for PHP version (7.4, 8.2, 8.3, 8.4, or 8.5)
2. Prompts for domain names (supports multiple domains for one site)
3. Optionally enables deploy versioning with timestamped folders
4. Optionally configures Supervisor-managed frontend proxy (e.g. Nuxt)
5. Supports combined Laravel API + Frontend setup (proxy `/` to Node, route `/api`, `/sanctum`, `/storage`, `/broadcasting` to PHP-FPM)
6. Sets up webroot directory structure
7. Creates Nginx server block configuration with security headers
8. Optionally installs Let's Encrypt SSL certificate
9. Optionally creates MySQL database and user

## 3. git_bare_deploy.sh

This script sets up a Git bare repository with a `post-receive` hook for push-to-deploy, with support for Supervisor-managed processes.

### Usage

```bash
chmod +x git_bare_deploy.sh
sudo ./git_bare_deploy.sh
```

### What it does:
1. Creates a `deployer` user with SSH access and NVM
2. Sets up a bare Git repository at `/var/git-bare/<domain>.git`
3. Generates a `post-receive` hook with configurable steps
4. Optionally enables versioned deploys with timestamped folders

### Deploy options (interactive prompts):

| Option | Description |
|---|---|
| Composer install | `composer install --no-dev --optimize-autoloader` |
| Artisan migrate | `php artisan migrate --force` |
| npm install + build | With NVM support and auto-detect Node version from `package.json` |
| Supervisor frontend | Nuxt/Node app managed by Supervisor (auto-detect available port) |
| Frontend .env symlink | Symlink `.env` into a frontend subdirectory |
| Laravel Horizon | Queue worker with graceful terminate on deploy |
| Laravel Reverb | WebSocket server (configurable port, default 24678) |
| Schedule worker | `php artisan schedule:work` via Supervisor |
| Vendor publish | `php artisan vendor:publish` with optional tag |
| Public storage link | Symlink `storage/app/public` → `public/storage` |
| PHP-FPM reload | `systemctl reload php<version>-fpm` after deploy |

### Supervisor Configuration

For each enabled service, the script generates Supervisor config files at `/etc/supervisor/conf.d/<domain>-<service>.conf`:

- `<domain>-nuxt.conf` — Frontend Node app
- `<domain>-horizon.conf` — Laravel Horizon
- `<domain>-reverb.conf` — Laravel Reverb
- `<domain>-schedule.conf` — Laravel schedule:work

### Deploying Your Application

1. Add the deployment remote (shown after running the script):
   ```bash
   git remote add live ssh://deployer@your-server-ip/var/git-bare/your-domain.com.git
   ```

2. Deploy your application:
   ```bash
   git push live main
   ```

## 4. deploy_at_the_server.sh

A concrete zero-downtime deploy script meant to be customized per project. Clones from a Git repo, runs composer/npm, swaps the `current` symlink, and restarts Supervisor processes.

### Usage

```bash
chmod +x deploy_at_the_server.sh
sudo ./deploy_at_the_server.sh
```

### What it does:
1. Clones the repo into a timestamped release folder
2. Symlinks shared `.env` and storage
3. Runs `composer install` and `php artisan migrate`
4. Builds frontend (`npm install && npm run build`)
5. Fixes permissions for `www-data`
6. Swaps the `current` symlink to the new release
7. Restarts frontend via Supervisor
8. Reloads Nginx
9. Cleans up old releases (keeps last 3)

## 5. server_migration.sh

rsync-based migration script for moving from an old server to a new one.

### What it migrates:
- Web files (`/var/www/`)
- Git bare repos (`/var/git-bare/`)
- Nginx configs (`/etc/nginx/sites-available/`, `sites-enabled/`)
- Let's Encrypt certificates (`/etc/letsencrypt/`)
- MySQL dump (all databases)
- TeamSpeak data

## Architecture Patterns

- **Versioned deploys**: Timestamped release folders under `deploys/` with a `current` symlink, plus optional rollback script generation.
- **Combined Laravel + Supervisor frontend**: Nginx proxies `/` to a Supervisor-managed Node app while routing `/api`, `/sanctum`, `/storage`, `/broadcasting` to PHP-FPM.
- **Deployer user**: `git_bare_deploy.sh` creates a `deployer` system user with passwordless sudo and NVM, used for SSH-based push deploys.
- **Standard paths**: Web roots at `/var/www/<domain>`, bare repos at `/var/git-bare/<domain>.git`.

## Best Practices

1. **Security**:
   - Always use strong passwords
   - Keep your server and software updated
   - Use SSH keys instead of password authentication
   - Regularly backup your databases and important files

2. **Deployment**:
   - Test deployments on a staging environment first
   - Use version control for all your code
   - Keep sensitive information in environment variables

3. **Maintenance**:
   - Set up log rotation
   - Monitor server resources
   - Regularly check for security updates

## Troubleshooting

- **Permission issues**: Ensure the web server user (www-data) has proper permissions on web directories
- **Nginx errors**: Check logs at `/var/log/nginx/error.log`
- **PHP errors**: Check logs at `/var/log/php<version>-fpm.log`
- **MySQL issues**: Check logs at `/var/log/mysql/error.log`
- **Supervisor issues**: Check logs at `/var/log/supervisor/` and use `sudo supervisorctl status`

## License

This project is open source and available under the [MIT License](LICENSE).
