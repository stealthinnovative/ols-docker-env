# phpMyAdmin Setup Options

Choose between two phpMyAdmin configurations. Both use the same `.env` file.

---

## Quick Start

1. **Edit the `.env` file** with your passwords:
```bash
   nano .env  # or your preferred editor
```
   
   Change these values:
```bash
   MYSQL_ROOT_PASSWORD=your_super_secure_root_password_123  # ← CHANGE THIS!
   MYSQL_PASSWORD=your_secure_app_password_456              # ← CHANGE THIS!
```

2. **Choose your phpMyAdmin setup** (see options below)

---

## Option 1: Standard Setup (Recommended)

**Simple phpMyAdmin with built-in Apache web server.**

### Start:
```bash
docker compose up -d
```

### Access:
http://localhost:8080

### Features:
- ✅ Zero configuration needed
- ✅ Works immediately
- ✅ Independent of OpenLiteSpeed
- ✅ Perfect for development

### Use this if:
- You just need phpMyAdmin to work
- You want simplicity
- You're new to Docker
- It's a development environment

---

## Option 2: FPM Setup (Advanced)

**phpMyAdmin proxied through OpenLiteSpeed via PHP-FPM.**

### Start:
```bash
# 1. Switch to FPM compose file
cp docker-compose.fpm.yml docker-compose.yml

# 2. Run the FPM setup script
./bin/phpmyadmin.sh
```

### Access:
http://localhost:8080

### Features:
- ✅ All traffic through OpenLiteSpeed
- ✅ Can apply OpenLiteSpeed features (rate limiting, caching, access control)
- ✅ Consistent with main application architecture
- ✅ Single port entry point

### Use this if:
- You want everything through OpenLiteSpeed
- You need OpenLiteSpeed's security/caching features
- You're comfortable with advanced configurations
- It's a production environment with specific requirements

---

## Switching Between Versions

Both setups use the **same `.env` file** - no need to reconfigure!

### Standard → FPM:
```bash
docker compose down
cp docker-compose.fpm.yml docker-compose.yml
./bin/phpmyadmin.sh
```

### FPM → Standard:
```bash
docker compose down
git checkout docker-compose.yml  # Restore original
docker compose up -d
```

---

## Login Credentials

After setup, access phpMyAdmin at http://localhost:8080

**Administrator Access:**
- Username: `root`
- Password: (your `MYSQL_ROOT_PASSWORD` from `.env`)

**Application User Access:**
- Username: (your `MYSQL_USER` from `.env`, default: `wordpress`)
- Password: (your `MYSQL_PASSWORD` from `.env`)

---

## Troubleshooting

### Standard Setup Issues:

**Port 8080 already in use:**
```bash
# Check what's using port 8080
lsof -i :8080

# Stop conflicting service or change port in docker-compose.yml
```

**Can't connect to database:**
- Verify `MYSQL_ROOT_PASSWORD` in `.env` is correct
- Check containers are running: `docker compose ps`
- Check logs: `docker compose logs phpmyadmin`

### FPM Setup Issues:

**phpMyAdmin not accessible after script:**
```bash
# Check all containers are running
docker compose ps

# View OpenLiteSpeed logs
docker compose logs litespeed

# View phpMyAdmin FPM logs
docker compose logs phpmyadmin

# Verify phpMyAdmin files are present
docker compose exec litespeed ls -la /var/www/vhosts/phpmyadmin
```

**Login fails (page loads but can't authenticate):**
- This is exactly what the setup script tests for!
- Check script output - it tests both root and user login
- Verify `PMA_HOST` is set to `mysql` in docker-compose
- Confirm MySQL is healthy: `docker compose exec mysql mysqladmin ping`

**Re-run setup script:**
```bash
# The script is idempotent - safe to run multiple times
./bin/phpmyadmin.sh
```

---

## Configuration Reference

### Environment Variables (`.env`):

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `MYSQL_ROOT_PASSWORD` | ✅ Yes | - | MySQL root password |
| `MYSQL_DATABASE` | ✅ Yes | - | Database name |
| `MYSQL_USER` | ✅ Yes | - | Database user |
| `MYSQL_PASSWORD` | ✅ Yes | - | Database user password |
| `TIMEZONE` | ✅ Yes | - | Server timezone |
| `DOMAIN` | No | `localhost` | Domain name |
| `MARIADB_MAX_CONNS` | No | `200` | Max MySQL connections |
| `LITESPEED_IMAGE` | No | `1.8.5-lsphp85` | OpenLiteSpeed version |
| `MARIADB_IMAGE` | No | `mariadb:lts-noble` | MariaDB version |
| `REDIS_IMAGE` | No | `redis:alpine` | Redis version |
| `PHPMYADMIN_IMAGE` | No | Varies* | phpMyAdmin version |

*Default varies by setup:
- Standard: `latest` (Apache-based)
- FPM: `fpm-alpine` (PHP-FPM only)

---

## File Structure
```
project/
├── docker-compose.yml          # Standard setup (default)
├── docker-compose.fpm.yml      # FPM setup (advanced)
├── .env                        # Your configuration (edit this!)
├── bin/
│   └── phpmyadmin.sh          # FPM setup script
├── lsws/                      # OpenLiteSpeed configs (auto-generated)
├── phpmyadmin/                # phpMyAdmin files (FPM only)
├── data/db/                   # MySQL data
├── redis/                     # Redis data
└── logs/                      # OpenLiteSpeed logs
```

---

## Additional Notes

### Security Recommendations:

1. **Change default passwords** in `.env` before first run
2. **Use strong passwords** (20+ characters, mixed case, numbers, symbols)
3. **Restrict phpMyAdmin access** in production (firewall rules, VPN, etc.)
4. **Keep images updated** regularly

### Performance Tips:

- For servers with 8GB+ RAM, uncomment `MARIADB_MAX_CONNS=400` in `.env`
- Monitor resource usage: `docker stats`
- Adjust OpenLiteSpeed tuning in `lsws/conf/httpd_config.conf` (FPM setup only)

### Backup Important Data:
```bash
# Backup database
docker compose exec mysql mysqldump -u root -p$MYSQL_ROOT_PASSWORD --all-databases > backup.sql

# Backup volumes
tar -czf backup-data.tar.gz data/ redis/ lsws/
```

---

## Need Help?

- Check container logs: `docker compose logs [service_name]`
- View all containers: `docker compose ps`
- Restart services: `docker compose restart [service_name]`
- Full reset: `docker compose down && docker compose up -d`

For FPM setup issues, the `phpmyadmin.sh` script provides detailed debugging output.