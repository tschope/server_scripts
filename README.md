# Server Setup and Deployment Scripts

This repository contains three essential shell scripts for setting up and managing a LEMP (Linux, Nginx, MySQL, PHP) server environment and deploying web applications.

## Scripts Overview

1. **server_lemp_setup.sh** - Initial server setup with LEMP stack
2. **script_domain_generate.sh** - Configures Nginx for new domains
3. **git_bare_deploy.sh** - Sets up Git-based deployment for projects

## Prerequisites

- Ubuntu/Debian-based Linux server
- Sudo/root access
- Basic knowledge of Linux command line

## 1. server_lemp_setup.sh

This script performs the initial server setup, including:
- SSH security configuration
- Firewall setup (UFW)
- LEMP stack installation (Linux, Nginx, MySQL, PHP)
- Composer and Node.js installation
- Basic security configurations

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
   - PHP with common extensions
   - Composer (PHP package manager)
   - Node.js and npm
4. Sets up basic firewall rules
5. Configures basic server security

**Note:** The MySQL root password will be saved to `/root/mysql_root_password.txt`.

## 2. script_domain_generate.sh

This script helps you set up a new domain with Nginx, including PHP-FPM configuration and SSL certificates using Let's Encrypt.

### Usage

```bash
chmod +x script_domain_generate.sh
sudo ./script_domain_generate.sh
```

### What it does:
1. Asks for PHP version (7.4, 8.3, or 8.4)
2. Prompts for domain names (supports multiple domains for one site)
3. Sets up webroot directory structure
4. Creates Nginx server block configuration
5. Enables the site in Nginx
6. Optionally installs Let's Encrypt SSL certificate
7. Sets up automatic certificate renewal

### Example
```
Enter PHP version to use [default: 8.3]: 8.3
Enter domain(s) (space-separated, e.g. domain.com www.domain.com): example.com www.example.com
Enter webroot subfolder [default: /public]: /public
Enter base path for web root [default: /var/www]: /var/www
```

## 3. git_bare_deploy.sh

This script sets up a Git bare repository for deployment, allowing you to deploy your code by simply pushing to a remote repository.

### Usage

```bash
chmod +x git_bare_deploy.sh
sudo ./git_bare_deploy.sh
```

### What it does:
1. Creates a deployer user with necessary permissions
2. Sets up a bare Git repository
3. Configures Git hooks for automatic deployment
4. Sets up proper file permissions
5. Provides instructions for adding the remote repository
6. Automatically handles Node.js projects with `package.json`
7. Supports PM2 for process management (if configured)

### PM2 Configuration

For Node.js applications that should run continuously, you can add a PM2 configuration file. The script supports both `pm2.config.js` and `ecosystem.config.js` formats. Here's an example `pm2.config.js`:

```javascript
module.exports = {
  apps: [{
    name: 'your-app-name',
    script: 'app.js',  // or 'npm start' if using package.json scripts
    instances: 'max',
    autorestart: true,
    watch: false,
    max_memory_restart: '1G',
    env: {
      NODE_ENV: 'production',
    }
  }]
};
```

### Deploying Your Application

1. Add the deployment remote (you'll get this after running the script):
   ```bash
   git remote add live ssh://deployer@your-server-ip/var/git-bare/your-domain.com.git
   ```

2. Deploy your application:
   ```bash
   git push live main
   ```

3. The deployment script will automatically:
   - Install Node.js (version specified in package.json or latest LTS)
   - Run `npm install`
   - Execute `npm run build` if a build script exists
   - Restart your PM2 process if a config file is found

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
- **PHP errors**: Check logs at `/var/log/php[version]-fpm.log`
- **MySQL issues**: Check logs at `/var/log/mysql/error.log`

## License

This project is open source and available under the [MIT License](LICENSE).
