#!/bin/bash
set -euo pipefail

echo "🚀 OpenLiteSpeed phpMyAdmin VHOST + FPM (Volume Mounts Only)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# Load environment
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-your_super_secure_root_password_123}
echo "📁 Working: $PROJECT_ROOT"
echo "🗝️ MySQL root: $MYSQL_ROOT_PASSWORD"

# 1. Create directories
mkdir -p phpmyadmin lsws/conf/vhosts data/db sites logs redis/data

# 2. phpMyAdmin config (AUTO-LOGIN)
cat > phpmyadmin/config.user.inc.php << EOF
<?php
\$cfg['Servers'][1] = [
    'host' => 'mysql', 'port' => 3306,
    'auth_type' => 'config', 'user' => 'root', 
    'password' => '${MYSQL_ROOT_PASSWORD}'
];
\$cfg['PMA_AbsoluteUri'] = 'http://localhost:8080/';
\$cfg['blowfish_secret'] = 'test32bytekeyhereforpma!!!';
?>
EOF

# 3. OpenLiteSpeed MAIN config (FPM connection)
cat > lsws/conf/httpd_config.conf << 'EOF'
serverName LOMP-VHOST
user lsadm
group lsadm
root /usr/local/lsws

listener phpMyAdmin {
  address *:8080
}

externalApp phpmyadmin-fpm {
  type fpm
  address tcp://phpmyadmin-fpm:9000
  maxConns 50
  initTimeout 60
  persistConn 1
  runOnStartUp 1
}

include conf/vhosts/phpmyadmin.conf
EOF

# 4. phpMyAdmin VHOST (points to mounted volume)
cat > lsws/conf/vhosts/phpmyadmin.conf << 'EOF'
virtualhost phpmyadmin {
  vhRoot /usr/local/lsws/phpmyadmin
  enableGzip 1
  listener phpMyAdmin

  context / {
    type php
    location /usr/local/lsws/phpmyadmin/
    indexFiles index.php
    accessControl { allow * }
    phpIniOverride {
      php_admin_value open_basedir none
      upload_max_filesize 128M
      post_max_size 128M
    }
  }
}
EOF

# 5. Start services
echo "🐳 Starting LOMP stack..."
docker compose down 2>/dev/null || true
sleep 2
docker compose up -d

echo "⏳ Waiting 20s for services..."
sleep 20

# 6. **VOLUME MOUNT** - Copy phpMyAdmin files from FPM → LiteSpeed
echo "📦 Copying phpMyAdmin files via volume mount..."
docker compose exec litespeed mkdir -p /usr/local/lsws/phpmyadmin

# Copy from phpmyadmin-fpm's volume to LiteSpeed (HOST → HOST → LiteSpeed)
docker compose exec phpmyadmin-fpm cp -r /var/www/html/* /tmp/phpmyadmin-tmp/ || true
docker compose cp phpmyadmin-fpm:/tmp/phpmyadmin-tmp/. litespeed:/usr/local/lsws/phpmyadmin/

# Permissions
docker compose exec litespeed chown -R lsadm:lsadm /usr/local/lsws/phpmyadmin
docker compose exec litespeed chmod -R 755 /usr/local/lsws/phpmyadmin
docker compose exec litespeed find /usr/local/lsws/phpmyadmin -type f -exec chmod 644 {} \;

# 7. Copy config
docker compose cp phpmyadmin/config.user.inc.php litespeed:/usr/local/lsws/phpmyadmin/
docker compose exec litespeed chown lsadm:lsadm /usr/local/lsws/phpmyadmin/config.user.inc.php

# 8. Restart
echo "🔄 Restarting OpenLiteSpeed..."
docker compose exec litespeed /usr/local/lsws/bin/lswsctrl restart
sleep 8

# 9. Test
echo "🧪 TESTING..."
if curl -fs http://localhost:8080 >/dev/null 2>&1; then
  echo "✅ 🎉 phpMyAdmin: http://localhost:8080/ (AUTO-LOGIN)"
else
  echo "❌ DOWN - Check logs"
fi
echo "✅ OLS Admin: http://localhost:7080/"
docker compose ps
