#!/usr/bin/env bash
source .env 2>/dev/null || true

# Fixed: V2 only, standardized container names
COMPOSE_CMD="docker compose"
DOCKER_CMD="docker"
MYSQL_CONT="mysql"
REDIS_CONT="redis"

DOMAIN=$1
NOTE=${2:-""}

# Auto-detect cron job (no TTY + CRON_BACKUP env var)
IS_CRON=false
if [[ ! -t 0 && -n "$CRON_BACKUP" ]]; then
    NOTE="cron"
    IS_CRON=true
fi

# BACKUP_ROOT from .env, fallback to ./backups
BACKUP_ROOT="${BACKUP_ROOT:-./backups}"
DATE_TIME=$(date +%Y-%m-%d_%H-%M-%S)
SUFFIX=${IS_CRON:+"_cron"}

# FIXED FOLDER_NAME logic (no double underscore)
if [[ -n "$NOTE" ]]; then
  FOLDER_NAME="${DATE_TIME}_${NOTE}${SUFFIX}"
else
  FOLDER_NAME="${DATE_TIME}${SUFFIX}"
fi

BACKUP_DIR="${BACKUP_ROOT}/${DOMAIN}/${FOLDER_NAME}"
mkdir -p "$BACKUP_DIR" || { echo "❌ Failed to create $BACKUP_DIR"; exit 1; }

echo "🔄 Backing up ${DOMAIN} → ${BACKUP_DIR}"

# Get target database name from wp-config.php or env
TARGET_DB=$(grep "DB_NAME" "./sites/${DOMAIN}/wp-config.php" 2>/dev/null | cut -d\' -f4 || echo "${MARIADB_DATABASE}")

if [[ -z "$TARGET_DB" ]]; then
    echo "❌ Could not determine database for ${DOMAIN}"
    exit 1
fi

# 0. NEW: Flush Redis FIRST (WordPress object cache consistency)
echo "🗑️ Flushing Redis object cache..."
${DOCKER_CMD} exec ${REDIS_CONT} redis-cli FLUSHALL >/dev/null 2>&1 || true

# 1. NEW: Wait for MySQL healthy (your 30s healthcheck)
echo "⏳ Waiting for MySQL healthy (max 2min)..."
timeout 120 bash -c "until ${DOCKER_CMD} ps --filter 'name=${MYSQL_CONT}' --filter health=healthy | grep -q ${MYSQL_CONT}; do sleep 3; done" || {
    echo "❌ MySQL never became healthy - aborting backup"
    exit 1
}

# 2. Database backup (with progress via pv if available)
echo "📥 Dumping database ${TARGET_DB}..."
if command -v pv >/dev/null 2>&1; then
    ${DOCKER_CMD} exec ${MYSQL_CONT} mysqldump --single-transaction --quick --lock-tables=false "$TARGET_DB" | pv | gzip > "${BACKUP_DIR}/${DOMAIN}_db.sql.gz"
else
    ${DOCKER_CMD} exec ${MYSQL_CONT} mysqldump --single-transaction --quick --lock-tables=false "$TARGET_DB" | gzip > "${BACKUP_DIR}/${DOMAIN}_db.sql.gz"
fi

# 3. Site files backup (with progress)
echo "📁 Archiving site files..."
if command -v pv >/dev/null 2>&1; then
    tar -czf - -C ./sites "${DOMAIN}" | pv > "${BACKUP_DIR}/${DOMAIN}_site.tar.gz"
else
    tar -czf "${BACKUP_DIR}/${DOMAIN}_site.tar.gz" -C ./sites "${DOMAIN}"
fi

# 4. NEW: Validate backups
echo "🔍 Validating backups..."
if ! gunzip -c "${BACKUP_DIR}/${DOMAIN}_db.sql.gz" | head -5 >/dev/null 2>&1; then
    echo "❌ DB backup validation failed"
    exit 1
fi
echo "✅ DB backup valid ($(du -h "${BACKUP_DIR}/${DOMAIN}_db.sql.gz" | cut -f1))"

if ! tar -tzf "${BACKUP_DIR}/${DOMAIN}_site.tar.gz" >/dev/null 2>&1; then
    echo "❌ Files backup validation failed"
    exit 1
fi
echo "✅ Files backup valid ($(du -h "${BACKUP_DIR}/${DOMAIN}_site.tar.gz" | cut -f1))"

# 5. Fix permissions (more robust)
chmod 644 "${BACKUP_DIR}/${DOMAIN}_db.sql.gz" "${BACKUP_DIR}/${DOMAIN}_site.tar.gz"
chown -R 1000:1000 "$BACKUP_DIR" 2>/dev/null || true

# 6. Create restore manifest (enhanced)
cat > "${BACKUP_DIR}/restore-info.json" << EOF
{
  "domain": "${DOMAIN}",
  "timestamp": "${DATE_TIME}",
  "database": "${TARGET_DB}",
  "note": "${NOTE}",
  "backup_path": "${BACKUP_DIR}",
  "files": [
    "${DOMAIN}_db.sql.gz",
    "${DOMAIN}_site.tar.gz"
  ],
  "restore_command": "${COMPOSE_CMD} run --rm ${MYSQL_CONT} mariadb-dump ${DOMAIN} ${FOLDER_NAME##*/}",
  "docker_cmd": "${DOCKER_CMD}"
}
EOF

# 7. Backup stats
echo "📊 Backup stats:"
du -sh "$BACKUP_DIR"/*
echo "Total: $(du -sh "$BACKUP_DIR" | cut -f1)"

# 8. SMART PRUNING (enhanced safety)
echo "🧹 Pruning backups..."
if [[ "$IS_CRON" == true ]]; then
    echo "   📅 Cron mode: Keeping last 30 backups"
    find "${BACKUP_ROOT}/${DOMAIN}" -maxdepth 1 -type d \
        \( -name "*_cron*" ! -name "*Pre-Restore-AutoSave*" ! -name "*Pre-Copy-AutoSave*" \) | \
        sort -r | tail -n +31 | xargs -r rm -rf
else
    echo "   🙌 Manual mode: No pruning (unlimited)"
fi

# ALWAYS protect safety backups (keep last 5 only)
find "${BACKUP_ROOT}/${DOMAIN}" -maxdepth 1 -type d \
    \( -name "*Pre-Restore-AutoSave*" -o -name "*Pre-Copy-AutoSave*" \) | \
    sort -r | tail -n +6 | xargs -r rm -rf

echo "✅ Backup complete: ${BACKUP_DIR}"
echo "   📋 Restore with: ./bin/restore.sh ${DOMAIN} ${FOLDER_NAME##*/}"
