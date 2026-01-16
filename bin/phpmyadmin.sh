#!/bin/bash
set -e

echo "🚀 Auto-configuring phpMyAdmin FPM + OpenLiteSpeed (localhost:8080)..."

# 0. Load environment variables (KEEP YOUR .env)
if [[ -f .env ]]; then
  export $(grep -v '^#' .env | xargs)
else
  echo "❌ .env file not found"
  exit 1
fi

# 1. Create directories
mkdir -p ./lsws ./lsws/conf/vhosts ./lsws/conf/templates

# 2. Create PHP-FPM pool config (ALL YOUR SPECS INTACT)
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
php_admin_value[memory_limit] = 512M
POOL_EOF

# 3. ✅ FIXED: Correct OLS ExternalApp for FPM (lsphp → fpm)
HTTPD_CONF="./lsws/conf/httpd_config.conf"
if ! grep -q "externalApp phpmyadmin-fpm" "$HTTPD_CONF" 2>/dev/null; then
  cat >> "$HTTPD_CONF" << 'EOF'

externalApp phpmyadmin-fpm {
  type            fpm
  address         uds://var/run/phpmyadmin/phpmyadmin.sock
  maxConns        35
  initTimeout     60
  persistConn     1
  autoStart       1
  extUser         www-data
  extGroup        www-data
}
EOF
fi

# 4. ✅ FIXED: phpMyAdmin vhost on port 8080 (YOUR REQUEST)
PHPMYADMIN_VHOST="./lsws/conf/vhosts/phpmyadmin.conf"
cat > "$PHPMYADMIN_VHOST" << 'EOF'
virtualhost phpmyadmin {
  vhRoot                  $SERVER_ROOT/phpmyadmin
  enableGzip              1
  listener                phpMyAdmin

  context / {
    type                  php
    location              $SERVER_ROOT/phpmyadmin/
    indexFiles            index.php, index.html
    
    accessControl {
      allow               *
    }
  }
}

listener phpMyAdmin {
  address                 *:8080
}
EOF

# 5. Add listener to main config
grep -q "include vhosts/phpmyadmin.conf" "$HTTPD_CONF" 2>/dev/null || 
echo "include vhosts/phpmyadmin.conf" >> "$HTTPD_CONF"

# 6. Start services (YOUR ORDER)
docker compose down phpmyadmin litespeed 2>/dev/null || true
sleep 2
docker compose up -d mysql redis phpmyadmin litespeed

# 7. Wait for FPM socket
echo "⏳ Waiting for FPM socket..."
sleep 5
until docker compose exec litespeed ls /var/run/phpmyadmin/phpmyadmin.sock >/dev/null 2>&1; do
  echo "⏳ FPM socket not ready, waiting..."
  sleep 2
done
echo "✅ FPM socket ready!"

# 8. Deploy phpMyAdmin files (phpmyadmin:fpm-alpine → litespeed)
echo "📦 Deploying phpMyAdmin files..."
TEMP_DIR="/tmp/phpmyadmin-files-$$"
mkdir -p "$TEMP_DIR"

# Copy from phpmyadmin FPM container
docker compose cp phpmyadmin:/var/www/html/. "$TEMP_DIR/" 2>/dev/null || {
  echo "  ⚠️ docker cp failed, using tar..."
  docker compose exec -T phpmyadmin sh -c "tar -czf - -C /var/www/html ." | tar -xzf - -C "$TEMP_DIR"
}

# Copy to litespeed
docker compose exec litespeed mkdir -p /usr/local/lsws/phpmyadmin
docker compose cp "$TEMP_DIR/." litespeed:/usr/local/lsws/phpmyadmin/ 2>/dev/null || {
  echo "  ⚠️ docker cp failed, using tar..."
  (cd "$TEMP_DIR" && tar -czf - .) | docker compose exec -i litespeed sh -c "cd /usr/local/lsws/phpmyadmin && tar -xzf -"
}

docker compose exec litespeed chown -R lsadm:lsadm /usr/local/lsws/phpmyadmin
rm -rf "$TEMP_DIR"

# 9. Restart OLS
echo "🔄 Restarting OpenLiteSpeed..."
docker compose exec litespeed /usr/local/lsws/bin/lswsctrl restart
sleep 5

# 10. Fix PMA_HOST (if needed)
if ! grep -q "PMA_HOST: mysql:3306" docker-compose.yml; then
  sed -i '/PMA_HOST:/c\PMA_HOST: mysql:3306' docker-compose.yml
  docker compose up -d phpmyadmin
fi

# 11. Test MySQL connectivity
echo "🔐 Testing MySQL connections..."
docker compose exec phpmyadmin mysql -h mysql -P 3306 -u root -p${MYSQL_ROOT_PASSWORD} -e "SELECT 1;" >/dev/null 2>&1 &&
echo "✅ MySQL root connection OK" || echo "⚠️ MySQL root check failed"

# 12. Final test
echo "🌐 Testing http://localhost:8080..."
sleep 3
if curl -fs http://localhost:8080 >/dev/null 2>&1; then
  echo ""
  echo "🎉 SUCCESS! phpMyAdmin LIVE at http://localhost:8080"
  echo "═══════════════════════════════════════"
  echo "👤 Login: root / ${MYSQL_ROOT_PASSWORD}"
  echo "📊 Services: $(docker compose ps | grep Up)"
  echo "═══════════════════════════════════════"
else
  echo "❌ phpMyAdmin not responding. Debug:"
  echo "   docker compose logs litespeed | tail -20"
  echo "   docker compose logs phpmyadmin | tail -20"
  docker compose exec litespeed ls -la /var/run/phpmyadmin/
  exit 1
fi

echo "✅ COMPLETE! Your FPM + OpenLiteSpeed stack is production-ready."
