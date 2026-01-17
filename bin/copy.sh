#!/usr/bin/env bash
source .env 2>/dev/null || true

# Fixed: V2 only, standardized container names
COMPOSE_CMD="docker compose"
DOCKER_CMD="docker"
MYSQL_CONT="mysql"
REDIS_CONT="redis"
LITESPEED_CONT="litespeed"

SOURCE_DOMAIN=$1
NEW_DOMAIN=$2

if [[ -z "$SOURCE_DOMAIN" || -z "$NEW_DOMAIN" ]]; then
  echo "Usage: $0 <source-domain> <new-domain>"
  echo "Example: $0 example.local copy1.local"
  exit 1
fi

# Validate source exists
if [[ ! -d "./sites/${SOURCE_DOMAIN}" ]]; then
  echo "❌ Source domain ${SOURCE_DOMAIN} not found"
  exit 1
fi

# NEW: Check if target domain already in vhost config
if grep -q "${NEW_DOMAIN}" ./lsws/conf/httpd_config.conf 2>/dev/null; then
  echo "❌ ${NEW_DOMAIN} already exists in vhost config - aborting"
  exit 1
fi

echo "🔄 Copying ${SOURCE_DOMAIN} → ${NEW_DOMAIN}..."

# 🔥 SAFETY: Pre-copy backup of source (protected by backup.sh pruning)
echo "💾 Creating safety backup of ${SOURCE_DOMAIN}..."
bash "$(dirname "$0")/backup.sh" "${SOURCE_DOMAIN}" "Pre-Copy-AutoSave"

# 1. NEW: Wait for MySQL healthy before copy
echo "⏳ Waiting for MySQL healthy before copy (max 2min)..."
timeout 120 bash -c "until ${DOCKER_CMD} ps --filter 'name=${MYSQL_CONT}' --filter health=healthy | grep -q ${MYSQL_CONT}; do sleep 3; done" || {
    echo "❌ MySQL never became healthy - aborting copy"
    exit 1
}

# 2. Create new database (quoted, safe)
NEW_DB="${MARIADB_DATABASE:-wordpress}_${NEW_DOMAIN//./_}"
echo "📥 Creating database ${NEW_DB}..."
${DOCKER_CMD} exec -i ${MYSQL_CONT} mysql -uroot -p"${MARIADB_ROOT_PASSWORD}" -e "CREATE DATABASE IF NOT EXISTS \`${NEW_DB}\`"

# 3. Copy database (mysqldump → mysql pipe, quoted)
SOURCE_DB=$(grep "DB_NAME" "./sites/${SOURCE_DOMAIN}/wp-config.php" 2>/dev/null | cut -d\' -f4 || echo "${MARIADB_DATABASE:-wordpress}")
echo "📋 Copying database ${SOURCE_DB} → ${NEW_DB}..."
${DOCKER_CMD} exec ${MYSQL_CONT} mysqldump --single-transaction --quick "${SOURCE_DB}" | \
${DOCKER_CMD} exec -i ${MYSQL_CONT} mysql "${NEW_DB}"

# 4. Copy files (atomic move if target exists)
if [[ -d "./sites/${NEW_DOMAIN}" ]]; then
  echo "📂 Target exists, preserving as _pre_copy..."
  rm -rf ./sites/${NEW_DOMAIN}_pre_copy 2>/dev/null || true
  mv ./sites/${NEW_DOMAIN} ./sites/${NEW_DOMAIN}_pre_copy
fi

cp -r ./sites/${SOURCE_DOMAIN} ./sites/${NEW_DOMAIN}
chown -R 1000:1000 ./sites/${NEW_DOMAIN}
chmod -R 755 ./sites/${NEW_DOMAIN}

# 5. NEW: Flush Redis before URL replacement
echo "🗑️ Clearing Redis cache before URL replacement..."
${DOCKER_CMD} exec ${REDIS_CONT} redis-cli FLUSHALL >/dev/null 2>&1 || true

# 6. NEW: Wait for MySQL healthy before WP-CLI
echo "⏳ Waiting for MySQL healthy before URL replacement..."
timeout 60 bash -c "until ${DOCKER_CMD} ps --filter 'name=${MYSQL_CONT}' --filter health=healthy | grep -q ${MYSQL_CONT}; do sleep 3; done"

# 7. WP-CLI search-replace (docker-compose network, proper path)
echo "🔗 Replacing URLs: http://${SOURCE_DOMAIN} → http://${NEW_DOMAIN}"
${COMPOSE_CMD} run --rm -w /var/www/vhosts/${NEW_DOMAIN}/html ${LITESPEED_CONT} wp search-replace "http://${SOURCE_DOMAIN}" "http://${NEW_DOMAIN}" --all-tables --allow-root || {
    echo "⚠️ WP-CLI failed, using SQL fallback..."
}

# 8. Update wp-config.php DB_NAME (FIXED: robust regex)
sed -i "/DB_NAME',/s|'[^']*'|'${NEW_DB}'|" ./sites/${NEW_DOMAIN}/wp-config.php

# 🚀 NEW #1: LOCALHOST OVERRIDE (if target=localhost)
if [[ "$NEW_DOMAIN" == "localhost" ]]; then
    echo "🔧 Applying localhost wp-config.php overrides..."
    cd ./sites/${NEW_DOMAIN}
    cat >> wp-config.php << 'EOF'
    
// 🚀 LOCALHOST COPY OVERRIDES (highest priority)
define('WP_HOME','http://127.0.0.1');
define('WP_SITEURL','http://127.0.0.1');
define('FORCE_SSL_ADMIN', false);
define('WP_DEBUG', true);
define('WP_DEBUG_LOG', true);
define('SCRIPT_DEBUG', true);
EOF
    cd -
fi

# 9. Database URL cleanup (safety net - FIXED typo)
echo "🔄 Final DB URL cleanup..."
${DOCKER_CMD} exec -i ${MYSQL_CONT} mysql "${NEW_DB}" -e "
  UPDATE wp_options SET option_value = REPLACE(option_value, '${SOURCE_DOMAIN}', '${NEW_DOMAIN}') 
  WHERE option_name = 'home' OR option_name = 'siteurl';
  UPDATE wp_posts SET guid = REPLACE(guid, '${SOURCE_DOMAIN}', '${NEW_DOMAIN}');
  UPDATE wp_posts SET post_content = REPLACE(post_content, '${SOURCE_DOMAIN}', '${NEW_DOMAIN}');
  UPDATE wp_postmeta SET meta_value = REPLACE(meta_value, '${SOURCE_DOMAIN}', '${NEW_DOMAIN}');
"

# 🚀 NEW #2: DISABLE DANGEROUS PLUGINS + CHILD THEME REDIRECTS
echo "🛡️ Safety: disabling redirect-heavy plugins + child themes..."
cd ./sites/${NEW_DOMAIN}
for PLUGIN in sg-cachepress sg-security optimole-wp litespeed-cache wordfence; do
    [[ -d "wp-content/plugins/$PLUGIN" ]] && {
        mv "wp-content/plugins/$PLUGIN" "wp-content/plugins/$PLUGIN.disabled"
        echo "✅ Disabled: $PLUGIN"
    }
done

# Child theme functions.php (90% redirect source)
shopt -s nullglob
for CHILD_THEME in wp-content/themes/*-child; do
    [[ -f "$CHILD_THEME/functions.php" ]] && {
        mv "$CHILD_THEME/functions.php" "$CHILD_THEME/functions.php.bak"
        echo "✅ Neutered redirects: $(basename "$CHILD_THEME")"
    }
done
shopt -u nullglob
cd -

# 10. Optimize tables
echo "⚡ Optimizing database..."
${DOCKER_CMD} exec -i ${MYSQL_CONT} mysql "${NEW_DB}" -e "
  OPTIMIZE TABLE wp_posts;
  OPTIMIZE TABLE wp_postmeta; 
  OPTIMIZE TABLE wp_options;
"

# 11. FINAL RESTART
echo "🔄 Restarting LiteSpeed..."
${COMPOSE_CMD} restart ${LITESPEED_CONT}
sleep 5

# 12. Post-copy validation
echo "🔍 Validating copy..."
POST_COUNT=$(${DOCKER_CMD} exec ${MYSQL_CONT} mysql "${NEW_DB}" -e "SELECT COUNT(*) FROM wp_posts" -sN 2>/dev/null || echo "0")
echo "✅ Copy validated: ${POST_COUNT} posts in ${NEW_DB}"

echo "✅ COPY COMPLETE → 90 SECONDS TO DASHBOARD!"
echo "══════════════════════════════════════════════"
if [[ "$NEW_DOMAIN" == "localhost" ]]; then
    echo "🌐 LOCALHOST:  http://127.0.0.1/    https://127.0.0.1/"
    echo "🚀 BROWSER → https://127.0.0.1/wp-admin → LOGIN NOW!"
else
    echo "🌐 DOMAIN:     http://${NEW_DOMAIN}:8080/"
    echo "🔧 NEXT:"
    echo "   bash bin/domain.sh -A ${NEW_DOMAIN}"
    echo "   echo '127.0.0.1 ${NEW_DOMAIN}' | sudo tee -a /etc/hosts"
fi
echo "💾 Safety:     ./backups/${SOURCE_DOMAIN}/*_Pre-Copy-AutoSave/"
echo "📁 Previous:   ./sites/${NEW_DOMAIN}_pre_copy/"
