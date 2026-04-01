# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Language Policy

**CRITICAL**: This project has specific language requirements:
- All **explanations and communication** must be in **Portuguese-BR** or/and **English**
- All **code, documentation, comments, identifiers, filenames, and commit messages** must be in **English**
- All **marketing messages, release notes, and internal announcements** must be in **English**

## Overview

Collection of Bash shell scripts for provisioning and managing Ubuntu/Debian LEMP servers. All scripts are interactive (use `read -p` prompts) and require `sudo`/root access. They are meant to run directly on the target server, not locally.

## Scripts

| Script | Purpose |
|---|---|
| `server_lemp_setup.sh` | Full LEMP stack provisioning (SSH, UFW, Nginx, MySQL, PHP 7.4/8.3/8.4, Composer, Node.js/NVM, PM2, Certbot) |
| `script_domain_generate.sh` | Add a new domain: Nginx vhost, PHP-FPM, optional PM2 proxy, Let's Encrypt SSL, MySQL database/user creation |
| `git_bare_deploy.sh` | Create a bare Git repo with a `post-receive` hook for push-to-deploy (supports composer, artisan migrations, npm build, NVM, optional versioned deploys) |
| `deploy_at_the_server.sh` | Concrete zero-downtime deploy script (clone, composer, artisan migrate, npm build, symlink swap, PM2 restart, keeps last 3 releases) |
| `server_migration.sh` | rsync-based migration from old server (web files, git-bare repos, Nginx configs, Let's Encrypt certs, MySQL dump, TeamSpeak) |

## Architecture Patterns

- **Versioned deploys**: Both `script_domain_generate.sh` and `git_bare_deploy.sh` support timestamped release folders under `deploys/` with a `current` symlink, plus optional rollback script generation.
- **Combined Laravel + PM2 frontend**: `script_domain_generate.sh` can generate Nginx configs that proxy `/` to a PM2 Node app while routing `/api`, `/sanctum`, `/storage`, `/broadcasting` to PHP-FPM.
- **Deployer user**: `git_bare_deploy.sh` creates a `deployer` system user with passwordless sudo and NVM, used for SSH-based push deploys.
- **Standard paths**: Web roots at `/var/www/<domain>`, bare repos at `/var/git-bare/<domain>.git`.

## Conventions

- All scripts use `set -e` (fail on first error).
- Scripts are fully interactive via `read -p` — no CLI flags or argument parsing.
- PHP versions supported: 7.4, 8.3, 8.4. Default CLI is 8.3.
- Upload limits are set to 25MB in both Nginx (`client_max_body_size`) and PHP FPM (`upload_max_filesize`, `post_max_size`).
- MySQL root password is auto-generated and saved to `/root/mysql_root_password.txt`.
- Nginx security headers (X-Frame-Options, X-XSS-Protection, X-Content-Type-Options) and deny rules for `.env`, `.ht`, and sensitive directories are included by default.

## Testing

There are no automated tests. Scripts are validated by running them on actual servers. When modifying scripts, use `shellcheck` if available to catch common Bash issues.
