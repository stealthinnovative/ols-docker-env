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
  $0 staging.local /media/usb/wordpress-backup/
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

# Find DB file (prioritized patterns)
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

# Find WP/Files backup (prioritized patterns)
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

# 6. IMPORT DATABASE (multi-format)
echo "📥 Importing database..."
case "${DB_FILE##*.}" in
    gz)      gunzip -c "$DB_FILE" | $DOCKER_CMD exec -i $MYSQL_CONT mysql "$TARGET_DB" ;;
    sql)     cat "$DB_FILE" | $DOCKER_CMD exec -i $MYSQL_CMD mysql "$TARGET_DB" ;;
    zip)     unzip -p "$DB_FILE" "*.sql*" 2>/dev/null | $DOCKER_CMD exec -i $MYSQL_CONT mysql "$TARGET_DB" || {
                 echo "⚠️ ZIP SQL failed, trying GZ fallback..."
                 unzip -p "$DB_FILE" | gunzip | $DOCKER_CMD exec -i $MYSQL_CONT mysql "$TARGET_DB"
             } ;;
    *)       echo "❌ Unsupported DB format: ${DB_FILE##*.}"; exit 1 ;;
esac

# 7. EXTRACT FILES (multi-format)
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

# Fix permissions
chown -R 1000:1000 ./sites/${DOMAIN}
find ./sites/${DOMAIN} -type d -exec chmod 755 {} \;
find ./sites/${DOMAIN} -type f -exec chmod 644 {} \;

# 8. UPDATE wp-config.php
echo "🔧 Updating wp-config.php..."
cd ./sites/${DOMAIN}
if ! grep -q "DB_NAME', '${TARGET_DB}'" wp-config.php 2>/dev/null; then
    sed -i "s/DB_NAME', '[^']*'/DB_NAME', '${TARGET_DB}'/" wp-config.php
fi
cd - >/dev/null

# 9. CLEAR CACHES
echo "🗑️ Clearing Redis..."
$DOCKER_CMD exec $REDIS_CONT redis-cli FLUSHALL >/dev/null 2>/dev/null || true

# 10. ADD DOMAIN (if requested)
if [[ "$ADD_DOMAIN" == "--add-domain" ]]; then
    echo "🌐 Adding LiteSpeed vhost..."
    bash "$(dirname "$0")/domain.sh" -A "$DOMAIN"
    $COMPOSE_CMD restart $LITESPEED_CONT
fi

# 11. VALIDATE
echo "✅ VALIDATING..."
sleep 5
POST_COUNT=$($DOCKER_CMD exec $MYSQL_CONT mysql "$TARGET_DB" -e "SELECT COUNT(*) FROM wp_posts WHERE post_type='post' AND post_status='publish'" -sN 2>/dev/null || echo "0")
echo "🎉 RESTORED: ${POST_COUNT} published posts → http://${DOMAIN}:8080"

cat << EOF

✅ SUCCESS: ${DOMAIN} restored from ${BACKUP_DIR}
═══════════════════════════════════════════════
💾 Safety:    ./backups/${DOMAIN}/${TIMESTAMP}_PreRestore/
📁 Previous:  ./sites/${DOMAIN}_pre_restore/
🌐 Visit:     http://${DOMAIN}:8080
🔧 Hosts:     echo "127.0.0.1 ${DOMAIN}" | sudo tee -a /etc/hosts

EOF

[[ "$ADD_DOMAIN" != "--add-domain" ]] && echo "💡 Run: bash bin/domain.sh -A ${DOMAIN}"
