#!/bin/bash
set -e

echo "🚀 Auto-configuring phpMyAdmin FPM + OpenLiteSpeed (localhost:8080)..."

# 0. Set up paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"
cd "$PROJECT_ROOT"

echo "📁 Project root: $PROJECT_ROOT"

# Load .env
if [[ -f "$ENV_FILE" ]]; then
  echo "✅ Loading .env from $ENV_FILE"
  export $(grep -v '^#' "$ENV_FILE" | xargs)
else
  echo "❌ .env not found at $ENV_FILE"
  echo "Create .env with MYSQL_ROOT_PASSWORD, MYSQL_USER, MYSQL_PASSWORD, MYSQL_DATABASE, TIMEZONE"
  exit 1
fi

# Verify required env vars
REQUIRED_VARS=("MYSQL_ROOT_PASSWORD" "MYSQL_USER" "MYSQL_PASSWORD" "MYSQL_DATABASE")
for var in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var}" ]]; then
    echo "❌ Missing required variable: $var in .env"
    exit 1
  fi
done

echo "✅ All required environment variables found"

# 1. Create directory structure
echo "📁 Creating directory structure..."
mkdir -p lsws/conf/vhosts/phpmyadmin
mkdir -p phpmyadmin
mkdir -p data/db
mkdir -p redis/data
mkdir -p logs

# Create redis.conf if it doesn't exist
if [[ ! -f redis/redis.conf ]]; then
  echo "📝 Creating redis.conf..."
  cat > redis/redis.conf << 'EOF'
bind 0.0.0.0
protected-mode no
port 6379
dir /data
save 900 1
save 300 10
save 60 10000
EOF
fi

# 2. Create phpMyAdmin virtual host configuration
echo "📝 Configuring phpMyAdmin vhost..."
VHOST_CONF="lsws/conf/vhosts/phpmyadmin/vhconf.conf"
mkdir -p "$(dirname "$VHOST_CONF")"

# Check if vhost config exists and has phpMyAdmin content
if [[ -f "$VHOST_CONF" ]] && grep -q "phpmyadmin-fpm" "$VHOST_CONF" 2>/dev/null; then
  echo "✅ phpMyAdmin vhost config already exists - skipping"
else
  # Backup if file exists (we're about to modify/create it)
  if [[ -f "$VHOST_CONF" ]]; then
    BACKUP_FILE="$VHOST_CONF.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$VHOST_CONF" "$BACKUP_FILE"
    echo "💾 Backed up existing vhost config to: $BACKUP_FILE"
  fi
  
  cat > "$VHOST_CONF" << 'EOF'
docRoot                   /var/www/vhosts/phpmyadmin

index  {
  useServer               0
  indexFiles              index.php, index.html
}

errorlog {
  useServer               0
  logLevel                DEBUG
  rollingSize             10M
}

accesslog {
  useServer               0
  logFormat               "%h %l %u %t \"%r\" %>s %b"
  logHeaders              5
  rollingSize             10M
  keepDays                10
}

scripthandler  {
  add                     lsapi:phpmyadmin-fpm php
}

extprocessor phpmyadmin-fpm {
  type                    proxy
  address                 phpmyadmin-fpm:9000
  maxConns                10
  env                     PHP_LSAPI_CHILDREN=10
  initTimeout             60
  retryTimeout            0
  persistConn             1
  respBuffer              0
  pcKeepAliveTimeout      5
  notes                   phpMyAdmin FPM processor
}

rewrite  {
  enable                  1
  autoLoadHtaccess        1
}

context / {
  location                /var/www/vhosts/phpmyadmin/
  allowBrowse             1
  
  rewrite  {
    enable                1
  }
}
EOF
  echo "✅ Created phpMyAdmin vhost config"
fi

# 3. Configure main httpd_config.conf
echo "📝 Configuring httpd_config.conf..."
HTTPD_CONF="lsws/conf/httpd_config.conf"

# Check if httpd_config.conf exists
if [[ ! -f "$HTTPD_CONF" ]]; then
  # File doesn't exist - create complete config
  echo "📝 Creating new httpd_config.conf..."
  cat > "$HTTPD_CONF" << 'EOF'
serverName                localhost
user                      lsadm
group                     lsadm
priority                  0
autoRestart               1
chrootPath                /
enableChroot              0
inMemBufSize              120M
swappingDir               /tmp/lshttpd/swap
autoFix503                1

errorlog logs/error.log {
  logLevel                DEBUG
  debugLevel              0
  rollingSize             10M
  enableStderrLog         1
}

accesslog logs/access.log {
  rollingSize             10M
  keepDays                30
  compressArchive         1
}

indexFiles                index.html, index.php

expires  {
  enableExpires           1
}

autoLoadHtaccess          1

tuning  {
  maxConnections          2000
  maxSSLConnections       1000
  connTimeout             300
  maxKeepAliveReq         10000
  smartKeepAlive          0
  keepAliveTimeout        5
  sndBufSize              0
  rcvBufSize              0
  maxReqURLLen            32768
  maxReqHeaderSize        65536
  maxReqBodySize          2047M
  maxDynRespHeaderSize    32768
  maxDynRespSize          2047M
  maxCachedFileSize       4096
  totalInMemCacheSize     20M
  maxMMapFileSize         256K
  totalMMapCacheSize      40M
  useSendfile             1
  fileETag                28
  SSLCryptoDevice         null
  maxSSLCertLength        10000
  enableGzipCompress      1
  enableBrCompress        1
  enableDynGzipCompress   1
  gzipCompressLevel       6
  brCompressLevel         6
  compressibleTypes       text/*, application/x-javascript, application/javascript, application/xml, image/svg+xml,application/rss+xml
  gzipAutoUpdateStatic    1
  gzipStaticCompressLevel 6
  gzipMaxFileSize         10M
  gzipMinFileSize         300
}

listener phpMyAdminListener {
  address                 *:8080
  secure                  0
  map                     phpmyadmin *
}

virtualhost phpmyadmin {
  vhRoot                  /var/www/vhosts/phpmyadmin
  configFile              conf/vhosts/phpmyadmin/vhconf.conf
  allowSymbolLink         1
  enableScript            1
  restrained              0
  setUIDMode              0
}
EOF
  echo "✅ Created new httpd_config.conf with phpMyAdmin configuration"
else
  # File exists - check if phpMyAdmin config is already present
  if grep -q "listener phpMyAdminListener" "$HTTPD_CONF" && grep -q "virtualhost phpmyadmin" "$HTTPD_CONF"; then
    echo "✅ phpMyAdmin configuration already exists in httpd_config.conf - skipping"
  else
    # Need to add phpMyAdmin config - create backup first
    BACKUP_FILE="$HTTPD_CONF.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$HTTPD_CONF" "$BACKUP_FILE"
    echo "💾 Backed up existing httpd_config.conf to: $BACKUP_FILE"
    
    # Append phpMyAdmin configuration
    cat >> "$HTTPD_CONF" << 'EOF'

# phpMyAdmin Configuration
listener phpMyAdminListener {
  address                 *:8080
  secure                  0
  map                     phpmyadmin *
}

virtualhost phpmyadmin {
  vhRoot                  /var/www/vhosts/phpmyadmin
  configFile              conf/vhosts/phpmyadmin/vhconf.conf
  allowSymbolLink         1
  enableScript            1
  restrained              0
  setUIDMode              0
}
EOF
    echo "✅ Added phpMyAdmin configuration to existing httpd_config.conf"
  fi
fi

# 4. Start services (no dependencies - script handles orchestration)
echo "🐳 Starting services..."
docker compose down 2>/dev/null || true
sleep 2

echo "⏳ Starting mysql and redis..."
docker compose up -d mysql redis
sleep 10

echo "⏳ Waiting for MySQL to be healthy..."
MAX_WAIT=60
ELAPSED=0
until docker compose exec mysql mysqladmin ping -h localhost --silent 2>/dev/null; do
  if [ $ELAPSED -ge $MAX_WAIT ]; then
    echo "❌ MySQL failed to become healthy after ${MAX_WAIT}s"
    exit 1
  fi
  echo "   MySQL not ready yet... (${ELAPSED}s)"
  sleep 3
  ELAPSED=$((ELAPSED + 3))
done
echo "✅ MySQL is healthy"

echo "⏳ Starting phpMyAdmin..."
docker compose up -d phpmyadmin
sleep 5

echo "⏳ Starting OpenLiteSpeed..."
docker compose up -d litespeed
sleep 5

# 5. Copy phpMyAdmin files from FPM container to host (which litespeed mounts)
echo "📦 Deploying phpMyAdmin files..."

# Check if files already exist on host
if [[ -f "./phpmyadmin/index.php" ]]; then
  echo "✅ phpMyAdmin files already present on host - skipping copy"
else
  # Create temp directory
  TEMP_DIR="/tmp/phpmyadmin-files-$$"
  mkdir -p "$TEMP_DIR"

  # Copy from phpmyadmin container to temp
  echo "   Extracting files from phpMyAdmin container..."
  docker compose exec -T phpmyadmin sh -c "tar -czf - -C /var/www/html ." | tar -xzf - -C "$TEMP_DIR"

  # Move from temp to host phpmyadmin folder
  echo "   Copying files to host ./phpmyadmin/..."
  cp -r "$TEMP_DIR"/. ./phpmyadmin/

  rm -rf "$TEMP_DIR"
  echo "✅ phpMyAdmin files deployed to ./phpmyadmin/ (mounted by OpenLiteSpeed)"
fi

# Ensure proper permissions in litespeed container
docker compose exec litespeed chown -R lsadm:lsadm /var/www/vhosts/phpmyadmin 2>/dev/null || true
docker compose exec litespeed chmod -R 755 /var/www/vhosts/phpmyadmin 2>/dev/null || true

# 6. Restart OpenLiteSpeed to load new config
echo "🔄 Restarting OpenLiteSpeed..."
docker compose exec litespeed /usr/local/lsws/bin/lswsctrl restart
sleep 8

# 7. Test MySQL connectivity from phpMyAdmin container (database layer)
echo "🔐 Testing MySQL connectivity from phpMyAdmin container..."
if docker compose exec -T phpmyadmin mysql -h mysql -P 3306 -u root -p${MYSQL_ROOT_PASSWORD} -e "SELECT 1;" >/dev/null 2>&1; then
  echo "✅ MySQL connection successful (database layer)"
else
  echo "⚠️  MySQL connection test failed"
  echo "   Check MYSQL_ROOT_PASSWORD in .env"
fi

# 8. Test phpMyAdmin web interface accessibility
echo "🌐 Testing http://localhost:8080..."
sleep 3

MAX_RETRIES=10
RETRY_COUNT=0
SUCCESS=false

while [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; do
  if curl -fs http://localhost:8080 >/dev/null 2>&1; then
    SUCCESS=true
    break
  fi
  RETRY_COUNT=$((RETRY_COUNT + 1))
  echo "   Attempt $RETRY_COUNT/$MAX_RETRIES..."
  sleep 2
done

# 9. Test actual phpMyAdmin login (the real test!)
if [[ "$SUCCESS" == true ]]; then
  echo "🔑 Testing phpMyAdmin login with credentials..."
  
  # Test 1: Root user login
  echo "   Testing root user..."
  COOKIE_FILE="/tmp/phpmyadmin-test-root-$$"
  
  LOGIN_RESPONSE=$(curl -s -c "$COOKIE_FILE" -b "$COOKIE_FILE" \
    -d "pma_username=root" \
    -d "pma_password=${MYSQL_ROOT_PASSWORD}" \
    -d "server=1" \
    -d "target=index.php" \
    -d "token=" \
    http://localhost:8080/index.php)
  
  ROOT_LOGIN_SUCCESS=false
  if echo "$LOGIN_RESPONSE" | grep -qi "access denied\|cannot log in\|error\|mysql said"; then
    echo "   ❌ Root login FAILED - access denied or connection error"
    echo "      Check MYSQL_ROOT_PASSWORD and PMA_HOST configuration"
    SUCCESS=false
  elif echo "$LOGIN_RESPONSE" | grep -qi "pma_username\|login"; then
    echo "   ❌ Root login FAILED - still showing login page"
    echo "      Database connection may not be working correctly"
    SUCCESS=false
  else
    echo "   ✅ Root login successful"
    ROOT_LOGIN_SUCCESS=true
    
    # Verify root can access databases
    MAIN_PAGE=$(curl -s -b "$COOKIE_FILE" http://localhost:8080/index.php?route=/server/databases)
    if echo "$MAIN_PAGE" | grep -qi "database\|table\|sql"; then
      echo "   ✅ Root has full database access"
    fi
  fi
  
  rm -f "$COOKIE_FILE"
  
  # Test 2: Regular user login
  echo "   Testing ${MYSQL_USER} user..."
  COOKIE_FILE="/tmp/phpmyadmin-test-user-$$"
  
  LOGIN_RESPONSE=$(curl -s -c "$COOKIE_FILE" -b "$COOKIE_FILE" \
    -d "pma_username=${MYSQL_USER}" \
    -d "pma_password=${MYSQL_PASSWORD}" \
    -d "server=1" \
    -d "target=index.php" \
    -d "token=" \
    http://localhost:8080/index.php)
  
  USER_LOGIN_SUCCESS=false
  if echo "$LOGIN_RESPONSE" | grep -qi "access denied\|cannot log in\|error\|mysql said"; then
    echo "   ❌ ${MYSQL_USER} login FAILED - access denied or connection error"
    echo "      Check MYSQL_USER and MYSQL_PASSWORD in .env"
    SUCCESS=false
  elif echo "$LOGIN_RESPONSE" | grep -qi "pma_username\|login"; then
    echo "   ❌ ${MYSQL_USER} login FAILED - still showing login page"
    echo "      Database connection may not be working correctly"
    SUCCESS=false
  else
    echo "   ✅ ${MYSQL_USER} login successful"
    USER_LOGIN_SUCCESS=true
    
    # Verify user can access their database
    DB_PAGE=$(curl -s -b "$COOKIE_FILE" "http://localhost:8080/index.php?route=/database/structure&db=${MYSQL_DATABASE}")
    if echo "$DB_PAGE" | grep -qi "table\|structure\|${MYSQL_DATABASE}"; then
      echo "   ✅ ${MYSQL_USER} can access ${MYSQL_DATABASE} database"
    else
      echo "   ⚠️  ${MYSQL_USER} may have limited database access"
    fi
  fi
  
  rm -f "$COOKIE_FILE"
  
  # Final assessment
  if [[ "$ROOT_LOGIN_SUCCESS" == true ]] && [[ "$USER_LOGIN_SUCCESS" == true ]]; then
    echo "🎉 All login credentials verified and working!"
  elif [[ "$ROOT_LOGIN_SUCCESS" == true ]]; then
    echo "⚠️  Root works but ${MYSQL_USER} login has issues"
  elif [[ "$USER_LOGIN_SUCCESS" == true ]]; then
    echo "⚠️  ${MYSQL_USER} works but root login has issues"
  else
    echo "❌ Both login attempts failed"
    SUCCESS=false
  fi
fi

echo ""
echo "═══════════════════════════════════════════════════════════"

if [[ "$SUCCESS" == true ]]; then
  echo "🎉 SUCCESS! phpMyAdmin is LIVE at http://localhost:8080"
  echo "═══════════════════════════════════════════════════════════"
  echo ""
  echo "📝 Login Credentials:"
  echo "   👤 Username: root"
  echo "   🔑 Password: ${MYSQL_ROOT_PASSWORD}"
  echo "   ---"
  echo "   👤 Username: ${MYSQL_USER}"
  echo "   🔑 Password: ${MYSQL_PASSWORD}"
  echo ""
  echo "📊 Container Status:"
  docker compose ps
  echo ""
  echo "═══════════════════════════════════════════════════════════"
  echo "✅ Setup COMPLETE! Safe to run this script again anytime."
else
  echo "❌ phpMyAdmin not accessible at http://localhost:8080"
  echo "═══════════════════════════════════════════════════════════"
  echo ""
  echo "🔍 Debugging Information:"
  echo ""
  echo "📊 Container Status:"
  docker compose ps
  echo ""
  echo "📋 OpenLiteSpeed Logs (last 20 lines):"
  docker compose logs litespeed | tail -20
  echo ""
  echo "📋 phpMyAdmin Logs (last 20 lines):"
  docker compose logs phpmyadmin | tail -20
  echo ""
  echo "🔧 Manual Debugging Commands:"
  echo "   docker compose logs litespeed"
  echo "   docker compose logs phpmyadmin"
  echo "   docker compose exec litespeed ls -la /var/www/vhosts/phpmyadmin"
  echo "   docker compose exec litespeed cat /usr/local/lsws/conf/httpd_config.conf"
  echo ""
  exit 1
fi