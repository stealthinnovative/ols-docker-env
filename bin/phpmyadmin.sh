#!/bin/bash
set -e

echo "🚀 Auto-configuring phpMyAdmin FPM + OpenLiteSpeed (localhost:8080)..."

# 0. Fix .env path (script in /bin/, .env in parent)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"
cd "$PROJECT_ROOT"

echo "📁 Project root: $PROJECT_ROOT"

# Load .env from project root
if [[ -f "$ENV_FILE" ]]; then
  echo "✅ Loading .env from $ENV_FILE"
  export $(grep -v '^#' "$ENV_FILE" | xargs)
else
  echo "❌ .env not found at $ENV_FILE"
  echo "Create .env with MYSQL_ROOT_PASSWORD, MYSQL_USER, etc."
  exit 1
fi

# 1. Create directories
mkdir -p lsws/conf/vhosts

# 2. ✅ NO FPM POOL CONFIG - Use phpMyAdmin built-in (crash-free)

# 3. ✅ FIXED ExternalApp for phpMyAdmin FPM default socket
HTTPD_CONF="lsws/conf/httpd_config.conf"
mkdir -p "$(dirname "$HTTPD_CONF")"

if ! grep -q "externalApp phpmyadmin-fpm" "$HTTPD_CONF" 2>/dev/null; then
  cat >> "$HTTPD_CONF" << 'EOF'

externalApp phpmyadmin-fpm {
  type            fpm
  address         uds://var/run/php-fpm/phpmyadmin.sock
  maxConns        35
  initTimeout     60
  persistConn     1
  autoStart       1
  extUser         www-data
  extGroup        www-data
}
EOF
  echo "✅ Added FPM ExternalApp"
fi

# 4. ✅ phpMyAdmin vhost + listener on 8080
PHPMYADMIN_VHOST="lsws/conf/vhosts/phpmyadmin.conf"
mkdir -p "$(dirname "$PHPMYADMIN_VHOST")"

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

# Include vhost
if ! grep -q "phpmyadmin.conf" "$HTTPD_CONF"; then
  echo "include conf/vhosts/phpmyadmin.conf" >> "$HTTPD_CONF"
fi

# 5. Start services
echo "🐳 Starting services..."
docker compose down phpmyadmin litespeed 2>/dev/null || true
sleep 2
docker compose up -d mysql redis phpmyadmin litespeed

# 6. Wait for FPM socket (phpMyAdmin default path)
echo "⏳ Waiting for phpMyAdmin FPM socket..."
sleep 5
until docker compose exec litespeed ls /var/run/php-fpm/phpmyadmin.sock >/dev/null 2>&1; do
  echo "⏳ Socket not ready (checking phpmyadmin logs...)"
  docker compose logs phpmyadmin | tail -3
  sleep 2
done
echo "✅ FPM socket ready at /var/run/php-fpm/phpmyadmin.sock"

# 7. Copy phpMyAdmin files from FPM container
echo "📦 Copying phpMyAdmin files..."
TEMP_DIR="/tmp/phpmyadmin-files-$$"
mkdir -p "$TEMP_DIR"

# From phpmyadmin → host
if ! docker compose cp phpmyadmin:/var/www/html/. "$TEMP_DIR/"; then
  echo "  → Using tar fallback..."
  docker compose exec -T phpmyadmin sh -c "tar -czf - -C /var/www/html ." | tar -xzf - -C "$TEMP_DIR"
fi

# Host → litespeed
docker compose exec litespeed mkdir -p /usr/local/lsws/phpmyadmin
if ! docker compose cp "$TEMP_DIR/." litespeed:/usr/local/lsws/phpmyadmin/; then
  echo "  → Using tar fallback..."
  (cd "$TEMP_DIR" && tar -czf - .) | docker compose exec -i litespeed sh -c "cd /usr/local/lsws/phpmyadmin && tar -xzf -"
fi

docker compose exec litespeed chown -R lsadm:lsadm /usr/local/lsws/phpmyadmin
rm -rf "$TEMP_DIR"
echo "✅ phpMyAdmin files deployed"

# 8. Restart OpenLiteSpeed
echo "🔄 Restarting OpenLiteSpeed..."
docker compose exec litespeed /usr/local/lsws/bin/lswsctrl restart
sleep 5

# 9. Fix PMA_HOST if needed
if ! grep -q "PMA_HOST:.*3306" docker-compose.yml; then
  sed -i '/PMA_HOST:/c\PMA_HOST: mysql:3306' docker-compose.yml
  echo "✅ Fixed PMA_HOST: mysql:3306"
  docker compose up -d phpmyadmin
  sleep 3
fi

# 10. Test MySQL connectivity
echo "🔐 Testing MySQL from phpMyAdmin..."
if docker compose exec phpmyadmin mysql -h mysql -P 3306 -u root -p${MYSQL_ROOT_PASSWORD} -e "SELECT 1;" >/dev/null 2>&1; then
  echo "✅ MySQL root connection OK"
else
  echo "⚠️ MySQL root test failed (check MYSQL_ROOT_PASSWORD)"
fi

# 11. Final test
echo "🌐 Testing http://localhost:8080..."
sleep 3
if curl -fs http://localhost:8080 >/dev/null 2>&1; then
  echo ""
  echo "🎉 SUCCESS! phpMyAdmin LIVE at http://localhost:8080"
  echo "═══════════════════════════════════════"
  echo "👤 root / ${MYSQL_ROOT_PASSWORD}"
  echo "👤 ${MYSQL_USER} / ${MYSQL_PASSWORD}"
  echo "📊 docker compose ps"
  docker compose ps
  echo "═══════════════════════════════════════"
else
  echo "❌ phpMyAdmin not accessible"
  echo "🔍 Debug:"
  echo "  docker compose logs litespeed | tail -20"
  echo "  docker compose logs phpmyadmin | tail -20"
  echo "  docker compose exec litespeed ls -la /var/run/php-fpm/"
  exit 1
fi

echo "✅ phpMyAdmin FPM + OpenLiteSpeed setup COMPLETE!"
