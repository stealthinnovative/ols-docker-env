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
# 1. Create required directories
############################################
mkdir -p ./lsws ./lsws/conf/vhosts ./lsws/conf/templates

############################################
# 2. Create PHP-FPM pool (OLS ↔ phpMyAdmin)
############################################
POOL_CONF="./lsws/php-fpm-pool.conf"

if [[ -e "$POOL_CONF" ]]; then
  echo "🧹 Removing existing php-fpm-pool.conf"
  rm -rf "$POOL_CONF"
fi

cat > "$POOL_CONF" << 'POOL_EOF'
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
# 3. Register externalApp in OLS (idempotent)
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
# 6. Deploy phpMyAdmin files (CORRECT WAY)
############################################
echo "📦 Deploying phpMyAdmin files..."
sleep 5

TEMP_DIR="/tmp/phpmyadmin-files-$$"
mkdir -p "$TEMP_DIR"

echo "  → Copying from phpMyAdmin container to host..."
docker compose cp phpmyadmin:/var/www/html/. "$TEMP_DIR/" 2>/dev/null || {
  echo "  ⚠️  docker cp failed, using tar fallback..."
  docker compose exec -T phpmyadmin sh -c \
    "tar -czf - -C /var/www/html ." | tar -xzf - -C "$TEMP_DIR"
}

echo "  → Copying from host to LiteSpeed container..."
docker compose exec litespeed mkdir -p /usr/local/lsws/phpmyadmin
docker compose cp "$TEMP_DIR/." litespeed:/usr/local/lsws/phpmyadmin/ 2>/dev/null || {
  echo "  ⚠️  docker cp failed, using tar fallb
