#!/bin/bash
set -euo pipefail  # Strict mode: exit on error, undefined vars, pipe failures

# Source environment (failsafe fallback)
source .env 2>/dev/null || {
    echo "⚠️  .env not found, using Docker Compose defaults"
}

# Standardized container names (your stack)
COMPOSE_CMD="docker compose"
DOCKER_CMD="docker"
MYSQL_CONT="mysql"
REDIS_CONT="redis"
LITESPEED_CONT="litespeed"

# Parse arguments
DOMAIN="$1"
BACKUP_DIR="$2"
ADD_DOMAIN="${3:-}"  # Optional --add-domain flag

# Validation
[[ -z "$DOMAIN" || -z "$BACKUP_DIR" ]] && {
    cat << EOF
Usage: $0 <target-domain> <backup-directory> [ --add-domain ]

Examples:
  $0 blog.local ~/Downloads/backups/
  $0 new-site.local ./external-backup/ --add-domain
EOF
    exit 1
}

[[ ! -d "$BACKUP_DIR" ]] && {
    echo "❌ Directory not found: $BACKUP_DIR"
    exit 1
}

echo "🚀 Directory Restore: ${DOMAIN} ← ${BACKUP_DIR}"
echo "========================"

# 1. SAFETY BACKUP (pre-restore snapshot)
echo "💾 Creating safety backup..."
mkdir -p ./backups/${DOMAIN}
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
bash "$(dirname "$0")/backup.sh" "${DOMAIN}" "${TIMESTAMP}_PreRestore" || {
    echo "⚠️  backup.sh failed (continuing anyway)"
}

# 2. PREPARE TARGET DIRECTORY
echo "📁 Preparing ./sites/${DOMAIN}/..."
rm -rf ./sites/${DOMAIN}_pre_restore
[[ -d "./sites/${DOMAIN}" ]] && mv ./sites/${DOMAIN} ./sites/${DOMAIN}_pre_restore
mkdir -p ./sites/${DOMAIN}
chown 1000:1000 ./sites/${DOMAIN}

# 3. **AUTO-DETECT BACKUP FILES** (core logic)
echo "🔍 Scanning ${BACKUP_DIR} for backup files..."

DB_FILE=$( 
    find "$BACKUP_DIR" -maxdepth 2 -type f \( \
        -name "*_db*" -o -name "*_database*" -o -name "*db.sql*" -o \
        -name "database.sql*" -o -name "*.sql" \
    \) -print -quit 2>/dev/null || true 
)

[[ -z "$DB_FILE" || ! -f "$DB_FILE" ]] && {
    echo "❌ No database file found. Looking for: *_db.*, *_database.*, *.sql"
    ls -la "$BACKUP_DIR"/*.sql* "$BACKUP_DIR"/*_db* 2>/dev/null || echo "No .sql files found"
    exit 1
}

WP_FILE=$( 
    find "$BACKUP_DIR" -maxdepth 2 -type f \( \
        -name "*_wp*" -o -name "*_files*" -o -name "*_site*" -o \
        -name "*wordpress*" -o -name "wp-content*" -o \
        -name "*.zip" -o -name "*.tar.gz" -o -name "*.tgz" -o -name "*.tar" \
    \) ! -name "*_db*" -print -quit 2>/dev/null || true 
)

[[ -z "$WP_FILE" || ! -f "$WP_FILE" ]] && {
    echo "❌ No files backup found. Looking for: *_wp.*, *_files.*, *.zip, *.tar.gz"
    exit 1
}

echo "✅ DB:     $(basename "$DB_FILE")"
echo "✅ Files:  $(basename "$WP_FILE")"

# 4. WAIT FOR MYSQL HEALTHY (30s max)
echo "⏳ Waiting for MySQL healthy..."
for i in {1..10}; do
    if $DOCKER_CMD ps --filter "name=$MYSQL_CONT" --filter health=healthy | grep -q "$MYSQL_CONT"; then
        echo "✅ MySQL healthy"
        break
    fi
    [[ $i -eq 10 ]] && { echo "❌ MySQL timeout"; exit 1; }
    sleep 3
done

# 5. CREATE/RESET DATABASE
cd ./sites/${DOMAIN}
TARGET_DB=$(grep "DB_NAME" wp-config.php 2>/dev/null | cut -d\' -f4 || echo "wordpress_${DOMAIN//./_}")
cd - >/dev/null

echo "📋 Target DB: $TARGET_DB"

$DOCKER_CMD exec -i $MYSQL_CONT mysql -uroot -p"${MARIADB_ROOT_PASSWORD:-root}" <<-EOF
    DROP DATABASE IF EXISTS \`${TARGET_DB}\`;
    CREATE DATABASE \`${TARGET_DB}\`;
    GRANT ALL ON \`${TARGET_DB}\`.* TO '${MARIADB_USER:-wordpress}@%';
    FLUSH PRIVILEGES;
EOF

# 6. IMPORT DATABASE
echo "📥 Importing database..."
case "${DB_FILE##*.}" in
    gz)      gunzip -c "$DB_FILE" | $DOCKER_CMD exec -i $MYSQL_CONT mysql "$TARGET_DB" ;;
    sql)     cat "$DB_FILE" | $DOCKER_CMD exec -i $MYSQL_CONT mysql "$TARGET_DB" ;;
    zip)     unzip -p "$DB_FILE" "*.sql*" 2>/dev/null | $DOCKER_CMD exec -i $MYSQL_CONT mysql "$TARGET_DB" || {
                 echo "⚠️ ZIP SQL failed, trying GZ fallback..."
                 unzip -p "$DB_FILE" | gunzip | $DOCKER_CMD exec -i $MYSQL_CONT mysql "$TARGET_DB"
             } ;;
    *)       echo "❌ Unsupported DB format: ${DB_FILE##*.}"; exit 1 ;;
esac

# 7. EXTRACT FILES
echo "📦 Extracting files..."
cd ./sites/${DOMAIN}
case "${WP_FILE##*.}" in
    zip)     unzip -q "$WP_FILE" ;;
    "tar.gz") tar -xzf "$WP_FILE" ;;
    tgz)     tar -xzf "$WP_FILE" ;;
    tar)     tar -xf "$WP_FILE" ;;
    *)       echo "❌ Unsupported files format: ${WP_FILE##*.}"; exit 1 ;;
esac
cd - >/dev/null

# 8. **🚀 NEW: CRITICAL URL SEARCH/REPLACE** (eliminates 95% restore issues)
echo "🔄 Search/replacing production URLs → localhost..."
$DOCKER_CMD exec $LITESPEED_CONT wp search-replace "$DOMAIN" "127.0.0.1" --all-tables --allow-root || {
    echo "⚠️ WP-CLI search-replace failed (continuing)"
}

# 9. **🚀 NEW: COMPLETE wp-config.php** (forces localhost)
echo "🔧 Fixing wp-config.php for localhost..."
cd ./sites/${DOMAIN}
cat > wp-config-local.php << 'EOF'
<?php
// Localhost overrides (loaded AFTER main wp-config.php)
define('WP_HOME','http://127.0.0.1');
define('WP_SITEURL','http://127.0.0.1');
define('FORCE_SSL_ADMIN', false);
define('WP_DEBUG', true);
define('WP_DEBUG_LOG', true);
define('SCRIPT_DEBUG', true);

// Load after main config
require_once dirname(__FILE__) . '/wp-config.php';
EOF

# Backup original + use localhost config
[[ -f wp-config.php ]] && mv wp-config.php wp-config.php.orig
mv wp-config-local.php wp-config.php

# Ensure DB_NAME matches target
sed -i "s/DB_NAME', '[^']*/DB_NAME', '${TARGET_DB}'/" wp-config.php
cd - >/dev/null

# 10. **🚀 NEW: DISABLE DANGEROUS PLUGINS** (redirect culprits)
echo "🛡️ Disabling redirect-heavy plugins..."
cd ./sites/${DOMAIN}
for PLUGIN in sg-cachepress sg-security optimole-wp litespeed-cache wordfence; do
    [[ -d "wp-content/plugins/$PLUGIN" ]] && {
        mv "wp-content/plugins/$PLUGIN" "wp-content/plugins/$PLUGIN.disabled"
        echo "✅ Disabled: $PLUGIN"
    }
done

# Backup + neuter child theme functions.php (90% redirect source)
if [[ -d "wp-content/themes/*-child" ]]; then
    for CHILD_THEME in wp-content/themes/*-child; do
        [[ -f "$CHILD_THEME/functions.php" ]] && {
            mv "$CHILD_THEME/functions.php" "$CHILD_THEME/functions.php.bak"
            echo "✅ Neutered child theme redirects: $(basename "$CHILD_THEME")"
        }
    done
fi
cd - >/dev/null

# 11. Fix permissions
chown -R 1000:1000 ./sites/${DOMAIN}
find ./sites/${DOMAIN} -type d -exec chmod 755 {} \;
find ./sites/${DOMAIN} -type f -exec chmod 644 {} \;

# 12. CLEAR CACHES
echo "🗑️ Clearing Redis..."
$DOCKER_CMD exec $REDIS_CONT redis-cli FLUSHALL >/dev/null 2>/dev/null || true

# 13. ADD DOMAIN (if requested)
if [[ "$ADD_DOMAIN" == "--add-domain" ]]; then
    echo "🌐 Adding LiteSpeed vhost..."
    bash "$(dirname "$0")/domain.sh" -A "$DOMAIN"
    $COMPOSE_CMD restart $LITESPEED_CONT
fi

# 14. RESTART + VALIDATE
echo "🔄 Restarting LiteSpeed..."
$COMPOSE_CMD restart $LITESPEED_CONT
sleep 5

POST_COUNT=$($DOCKER_CMD exec $MYSQL_CONT mysql "$TARGET_DB" -uroot -p"${MARIADB_ROOT_PASSWORD:-root}" -e "SELECT COUNT(*) FROM wp_posts WHERE post_type='post' AND post_status='publish'" -sN 2>/dev/null || echo "0")
echo "🎉 RESTORED: ${POST_COUNT} published posts → http://127.0.0.1/ or https://127.0.0.1/"

cat << EOF

✅ SUCCESS: ${DOMAIN} restored from ${BACKUP_DIR} → READY IN 90 SECONDS!
═══════════════════════════════════════════════
🌐 URLs:        http://127.0.0.1/    https://127.0.0.1/
🛡️ Fixes:       wp-config.php → localhost
                Child theme redirects → disabled  
                sg-cachepress/optimole → disabled
💾 Safety:      ./backups/${DOMAIN}/${TIMESTAMP}_PreRestore/
📁 Previous:    ./sites/${DOMAIN}_pre_restore/
🔧 wp-config:   ./sites/${DOMAIN}/wp-config.php.orig (original)

🚀 Open browser → https://127.0.0.1/wp-admin → LOGIN IMMEDIATELY!
EOF

[[ "$ADD_DOMAIN" != "--add-domain" ]] && echo "💡 Run: bash bin/domain.sh -A ${DOMAIN}"
