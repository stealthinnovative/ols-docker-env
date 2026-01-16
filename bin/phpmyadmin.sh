#!/bin/bash
set -euo pipefail

echo "🚀 OpenLiteSpeed phpMyAdmin VHOST + FPM (/var/www/phpmyadmin/)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-your_super_secure_root_password_123}
echo "📁 Working: $PROJECT_ROOT"
echo "🗝️ MySQL root: $MYSQL_ROOT_PASSWORD"

# 1. Create directories
mkdir -p phpmyadmin lsws/conf/vhosts data/db sites logs redis/data

# 2. phpMyAdmin config (AUTO-LOGIN)
cat > phpmyadmin/config.user.inc.php << EOF
<?php
\$cfg['Servers'][1] = [
    'host' => 'mysql',
    'port' => 3306,
    'auth_type' => 'config',
    'user' => 'root',
    'password' => '${MYSQL_ROOT_PASSWORD}',
    'AllowNoPasswordRoot' => true
];
\$cfg['PMA_AbsoluteUri'] = 'http://localhost:8080/';
\$cfg['blowfish_secret'] = 'test32bytekeyhereforpma!!!';
?>
EOF

# 3. OpenLiteSpeed MAIN config
cat > lsws/conf/httpd_config.conf << 'EOF'
serverName LOMP-VHOST
user lsadm
group lsadm
root /usr/local/lsws

listener phpMyAdmin {
  address *:8080
}

externalApp phpmyadmin-fpm {
  type                    fpm
  address                 tcp://phpmyadmin-fpm:9000
  maxConns                50
  initTimeout             60
  persistConn             1
  runOnStartUp            1
}

include conf/vhosts/phpmyadmin.conf
EOF

# 4. phpMyAdmin VHOST config (/var/www/phpmyadmin)
cat > lsws/conf/vhosts/phpmyadmin.conf << 'EOF'
virtualhost phpmyadmin {
  vhRoot                  /var/www/phpmyadmin
  enableGzip              1
  listener                phpMyAdmin

  context / {
    type                  php
    location              /var/www/phpmyadmin/
    indexFiles            index.php
    accessControl { allow * }
    phpIniOverride {
      php_admin_value open_basedir none
      upload_max_filesize 128M
      post_max_size 128M
      memory_limit 256M
    }
  }
}
EOF

# 5. Start everything - LIVE volume mounts handle files
echo "🐳 Starting LOMP stack..."
docker compose down 2>/dev/null || true
sleep 2
docker compose up -d

echo "⏳ Waiting 25s for services + volume population..."
sleep 25

# 6. Fix permissions on shared volume (one-time)
echo "🔧 Fixing permissions on shared volume..."
docker compose exec litespeed chown -R lsadm:lsadm /var/www/phpmyadmin
docker compose exec litespeed chmod -R 755 /var/www/phpmyadmin
docker compose exec litespeed find /var/www/phpmyadmin -type f -exec chmod 644 {} \; 2>/dev/null || true

# 7. Restart LiteSpeed
echo "🔄 Restarting OpenLiteSpeed..."
docker compose exec litespeed /usr/local/lsws/bin/lswsctrl restart
sleep 10

# 8. Test
echo "🧪 TESTING ACCESS..."
if curl -fs --max-time 10 http://localhost:8080 >/dev/null 2>&1; then
  echo "✅ 🎉 phpMyAdmin LIVE: http://localhost:8080/ (AUTO-LOGIN)"
else
  echo "❌ phpMyAdmin DOWN - check logs:"
  docker compose logs --tail=20 litespeed
fi

if curl -fs http://localhost:7080 >/dev/null 2>&1; then
  echo "✅ OLS WebAdmin: http://localhost:7080/ (admin/admin)"
fi

echo "═══════════════════════════════════════"
echo "🎉 LIVE ACCESS POINTS:"
echo "  📊 phpMyAdmin:     http://localhost:8080/ (AUTO-LOGIN)"
echo "  ⚙️  OLS WebAdmin:   http://localhost:7080/ (admin/admin)"
echo "  🌐 Main sites:     http://localhost:80/"
echo "  🗄️  MySQL:         localhost:3306"
echo "  🔴 Redis:          localhost:6379"
echo "═══════════════════════════════════════"
docker compose ps

echo "✅ SETUP COMPLETE - /var/www/phpmyadmin/ LIVE!"
