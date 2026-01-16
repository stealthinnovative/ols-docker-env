#!/bin/bash
set -e

echo "🚀 Auto-configuring phpMyAdmin FPM + OpenLiteSpeed..."

# 1. Create directories (socket will be created by php-fpm in the named volume)
mkdir -p ./lsws ./lsws/conf/vhosts

# 1a. Create php-fpm pool configuration to ensure socket is created at correct path
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

# 2. Add FPM pool to httpd_config.conf (append only)
cat >> ./lsws/conf/httpd_config.conf << 'EOF'

externalApp phpmyadmin-fpm {
  type                      lsphp
  address                   uds:///var/run/phpmyadmin/phpmyadmin.sock
  maxConns                  35
  env                       LSAPI_CHILDREN=10
  initTimeout               60
  retryTimeout              0
  priority                  0
}
EOF

# 3. Auto-detect vhost and add context
VHOST_DIR=$(find ./lsws/conf/vhosts -name "*.conf" -o -name "vhconf.conf" | head -1 | xargs dirname)
VHOST_CONF="$VHOST_DIR/vhconf.conf"

if [[ ! -f "$VHOST_CONF" ]]; then
  echo "⚠️  No vhost conf found, creating default..."
  VHOST_CONF="./lsws/conf/vhosts/default/vhconf.conf"
  mkdir -p "$(dirname "$VHOST_CONF")"
  echo "virtualhost default { }" > "$VHOST_CONF"
fi

# Backup and append context
cp "$VHOST_CONF" "${VHOST_CONF}.bak" 2>/dev/null || true
cat >> "$VHOST_CONF" << 'EOF'

context /phpmyadmin {
  type                    php
  location                $SERVER_ROOT/phpmyadmin/
  indexFiles              index.php
  
  phpConfig {
    pool                phpmyadmin-fpm
  }
  
  accessControl {
    allow                 *
  }
}
EOF

# 4. Ensure correct docker-compose.yml volume mapping (using named volume for cross-platform compatibility)
if ! grep -q "phpmyadmin-sockets:" docker-compose.yml; then
  echo "🔧 Ensuring named volume 'phpmyadmin-sockets' exists in docker-compose.yml..."
  # Check if volumes section exists, if not add it
  if ! grep -q "^volumes:" docker-compose.yml; then
    echo "" >> docker-compose.yml
    echo "volumes:" >> docker-compose.yml
    echo "  phpmyadmin-sockets:" >> docker-compose.yml
  elif ! grep -q "phpmyadmin-sockets:" docker-compose.yml; then
    # Volumes section exists but phpmyadmin-sockets is missing
    sed -i.bak '/^volumes:/a\  phpmyadmin-sockets:' docker-compose.yml 2>/dev/null || \
    perl -i -pe 's/^(volumes:)$/$1\n  phpmyadmin-sockets:/' docker-compose.yml 2>/dev/null || \
    echo "  phpmyadmin-sockets:" >> docker-compose.yml
  fi
fi

# 5. Deploy services
docker-compose down phpmyadmin litespeed 2>/dev/null || true
sleep 2
docker-compose up -d phpmyadmin litespeed mysql redis

# 6. Wait for services and test
echo "⏳ Waiting for services..."
sleep 10

if curl -s http://localhost/phpmyadmin > /dev/null; then
  echo "✅ SUCCESS! phpMyAdmin ready at http://localhost/phpmyadmin"
  echo "📊 MySQL: $(docker-compose ps mysql | grep Up || echo 'Not running')"
  echo "🌐 OLS:   $(docker-compose ps litespeed | grep Up || echo 'Not running')"
  echo "🐳 phpMyAdmin FPM: $(docker-compose ps phpmyadmin | grep Up || echo 'Not running')"
else
  echo "❌ phpMyAdmin not responding. Check logs:"
  docker-compose logs phpmyadmin litespeed | tail -20
fi
