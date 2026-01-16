#!/bin/bash
set -e

echo "🚀 Auto-configuring phpMyAdmin FPM + OpenLiteSpeed..."

# 1. Create directories (socket will be created by php-fpm in the named volume)
mkdir -p ./lsws ./lsws/conf/vhosts

# 1a. Create php-fpm pool configuration to ensure socket is created at correct path
# Remove if it exists as a directory or file
if [[ -d ./lsws/php-fpm-pool.conf ]]; then
  rm -rf ./lsws/php-fpm-pool.conf
elif [[ -f ./lsws/php-fpm-pool.conf ]]; then
  rm -f ./lsws/php-fpm-pool.conf
fi

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

# 3. Add phpMyAdmin context to docker template (used by localhost vhost)
TEMPLATE_FILE="./lsws/conf/templates/docker.conf"
if [[ ! -f "$TEMPLATE_FILE" ]]; then
  echo "⚠️  Template file not found, creating directory..."
  mkdir -p "$(dirname "$TEMPLATE_FILE")"
fi

# Check if context already exists
if ! grep -q "context /phpmyadmin" "$TEMPLATE_FILE" 2>/dev/null; then
  # Backup template
  cp "$TEMPLATE_FILE" "${TEMPLATE_FILE}.bak" 2>/dev/null || true
  
  # Add context before the closing brace of the template
  # Remove the last closing brace, add context, then add closing brace back
  sed -i.bak '$d' "$TEMPLATE_FILE" 2>/dev/null || true
  cat >> "$TEMPLATE_FILE" << 'EOF'

  context /phpmyadmin {
    type                    php
    location                $DOC_ROOT/phpmyadmin/
    indexFiles              index.php
    
    phpConfig {
      pool                phpmyadmin-fpm
    }
    
    accessControl {
      allow                 *
    }
  }
}
EOF
  echo "✅ Added phpMyAdmin context to docker template"
else
  echo "ℹ️  phpMyAdmin context already exists in template"
fi

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
docker compose down phpmyadmin litespeed 2>/dev/null || true
sleep 2
docker compose up -d phpmyadmin litespeed mysql redis

# 5a. Copy phpMyAdmin files to LiteSpeed (using host as intermediary)
echo "📦 Copying phpMyAdmin files..."
sleep 5  # Wait for phpMyAdmin container to be ready

# Create temp directory on host
TEMP_DIR="/tmp/phpmyadmin-files-$$"
mkdir -p "$TEMP_DIR"

# Copy from phpMyAdmin container to host
echo "  Copying from phpMyAdmin container to host..."
docker compose cp phpmyadmin:/var/www/html/. "$TEMP_DIR/" 2>/dev/null || {
  echo "  ⚠️  Direct copy failed, trying alternative method..."
  docker compose exec -T phpmyadmin sh -c "tar -czf - -C /var/www/html ." | tar -xzf - -C "$TEMP_DIR" 2>/dev/null || true
}

# Copy from host to LiteSpeed container
echo "  Copying from host to LiteSpeed container..."
docker compose cp "$TEMP_DIR/." litespeed:/usr/local/lsws/phpmyadmin/ 2>/dev/null || {
  echo "  ⚠️  Direct copy failed, trying exec method..."
  docker compose exec -T litespeed sh -c "mkdir -p /usr/local/lsws/phpmyadmin" || true
  cd "$TEMP_DIR" && tar -czf - . | docker compose exec -i litespeed sh -c "cd /usr/local/lsws/phpmyadmin && tar -xzf -" || true
  cd - > /dev/null
}

# Fix permissions
echo "  Fixing permissions..."
docker compose exec litespeed chown -R lsadm:lsadm /usr/local/lsws/phpmyadmin 2>/dev/null || true

# Create symlink in vhost document root (required for $DOC_ROOT to work)
echo "  Creating symlink in vhost document root..."
docker compose exec litespeed sh -c "ln -sf /usr/local/lsws/phpmyadmin /var/www/vhosts/localhost/html/phpmyadmin" 2>/dev/null || true

# Clean up temp directory
rm -rf "$TEMP_DIR"

# 5b. If template wasn't found earlier, try adding context now
if [[ ! -f "$TEMPLATE_FILE" ]]; then
  echo "📝 Adding context to template (template should exist now)..."
  sleep 2
  if docker compose exec litespeed test -f /usr/local/lsws/conf/templates/docker.conf; then
    docker compose exec litespeed sh -c "sed -i '\$d' /usr/local/lsws/conf/templates/docker.conf && cat >> /usr/local/lsws/conf/templates/docker.conf << 'TEMPLATE_EOF'

  context /phpmyadmin {
    type                    php
    location                \$DOC_ROOT/phpmyadmin/
    indexFiles              index.php
    
    phpConfig {
      pool                phpmyadmin-fpm
    }
    
    accessControl {
      allow                 *
    }
  }
}
TEMPLATE_EOF'"
  fi
fi

# Restart LiteSpeed to pick up configuration changes
echo "🔄 Restarting LiteSpeed..."
docker compose exec litespeed /usr/local/lsws/bin/lswsctrl restart || true
sleep 3

# 6. Wait for services and test
echo "⏳ Waiting for services..."
sleep 10

if curl -s http://localhost/phpmyadmin > /dev/null; then
  echo "✅ SUCCESS! phpMyAdmin ready at http://localhost/phpmyadmin"
  echo "📊 MySQL: $(docker compose ps mysql | grep Up || echo 'Not running')"
  echo "🌐 OLS:   $(docker compose ps litespeed | grep Up || echo 'Not running')"
  echo "🐳 phpMyAdmin FPM: $(docker compose ps phpmyadmin | grep Up || echo 'Not running')"
else
  echo "❌ phpMyAdmin not responding. Check logs:"
  docker compose logs phpmyadmin litespeed | tail -20
fi
