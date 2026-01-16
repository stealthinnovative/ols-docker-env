#!/bin/bash
set -e

echo "🚀 Auto-configuring phpMyAdmin FPM + OpenLiteSpeed..."

############################################
# 0. Load environment variables
############################################
if [[ -f .env ]]; then
  export $(grep -v '^#' .env | xargs)
else
  echo "❌ .env file not found"
  exit 1
fi

############################################
# 1. Create directories
############################################
mkdir -p ./lsws ./lsws/conf/vhosts ./lsws/conf/templates

############################################
# 2. Create PHP-FPM pool (OLS ↔ phpMyAdmin)
############################################
rm -f ./lsws/php-fpm-pool.conf

cat > ./lsws/php-fpm-pool.conf << 'POOL_EOF'
[phpmyadmin]
user = www-data
group = www-data
listen = /var/run/phpmyadmin/phpmyadmin.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 5

php_admin_value[error_log] = /proc/self/fd/2
php_admin_flag[log_errors] = on
POOL_EOF

############################################
# 3. Register externalApp in OLS
############################################
HTTPD_CONF="./lsws/conf/httpd_config.conf"

grep -q "externalApp phpmyadmin-fpm" "$HTTPD_CONF" 2>/dev/null || cat >> "$HTTPD_CONF" << 'EOF'

externalApp phpmyadmin-fpm {
  type            lsphp
  address         uds:///var/run/phpmyadmin/phpmyadmin.sock
  maxConns        35
  env             LSAPI_CHILDREN=10
  initTimeout     60
  retryTimeout    0
}
EOF

############################################
# 4. Add phpMyAdmin context to docker template
############################################
TEMPLATE_FILE="./lsws/conf/templates/docker.conf"

if ! grep -q "context /phpmyadmin" "$TEMPLATE_FILE" 2>/dev/null; then
  sed -i.bak '$d' "$TEMPLATE_FILE" 2>/dev/null || true
  cat >> "$TEMPLATE_FILE" << 'EOF'

  context /phpmyadmin {
    type        php
    location    $DOC_ROOT/phpmyadmin/
    indexFiles  index.php

    phpConfig {
      pool phpmyadmin-fpm
    }

    accessControl {
      allow *
    }
  }
}
EOF
fi

############################################
# 5. Start services
############################################
echo "🐳 Starting containers..."
docker compose down phpmyadmin litespeed 2>/dev/null || true
sleep 2
docker compose up -d mysql redis phpmyadmin litespeed

############################################
# 6. Deploy phpMyAdmin files to LiteSpeed
############################################
echo "📦 Deploying phpMyAdmin files..."
sleep 5

docker compose exec litespeed mkdir -p /usr/local/lsws/phpmyadmin
docker compose cp phpmyadmin:/var/www/html/. litespeed:/usr/local/lsws/phpmyadmin/

docker compose exec litespeed chown -R lsadm:lsadm /usr/local/lsws/phpmyadmin
docker compose exec litespeed ln -sf \
  /usr/local/lsws/phpmyadmin \
  /var/www/vhosts/localhost/html/phpmyadmin

############################################
# 7. Restart OpenLiteSpeed
############################################
echo "🔄 Restarting OpenLiteSpeed..."
docker compose exec litespeed /usr/local/lsws/bin/lswsctrl restart || true
sleep 5

############################################
# 8. TEST: phpMyAdmin → MySQL TCP login (ROOT)
############################################
echo ""
echo "🔐 Testing phpMyAdmin → MySQL TCP login (root)..."

if docker compose exec -T phpmyadmin \
  mysql -h mysql -P 3306 -u root \
  --password="${MYSQL_ROOT_PASSWORD}" \
  -e "SELECT 1;" >/dev/null 2>&1; then

  echo "✅ SUCCESS: phpMyAdmin can connect to MySQL as root over TCP"
else
  echo "❌ FAILURE: phpMyAdmin CANNOT connect to MySQL as root"
  echo ""
  echo "🔍 Diagnostics:"
  docker compose exec phpmyadmin env | grep PMA_
  echo ""
  echo "➡️  Check root host permissions:"
  echo "    docker compose exec mysql mysql -u root -p -e \"SELECT Host,User FROM mysql.user WHERE User='root';\""
  exit 1
fi

############################################
# 9. Final Web Test
############################################
echo ""
echo "🌐 Verifying web access..."

if curl -fs http://localhost/phpmyadmin >/dev/null; then
  echo "🎉 phpMyAdmin READY"
  echo ""
  echo "➡️  URL:      http://localhost/phpmyadmin"
  echo "➡️  Username: root"
  echo "➡️  Password: MYSQL_ROOT_PASSWORD (.env)"
  echo "➡️  Server:   (leave empty)"
else
  echo "❌ phpMyAdmin web interface not responding"
  docker compose logs phpmyadmin litespeed | tail -50
  exit 1
fi
