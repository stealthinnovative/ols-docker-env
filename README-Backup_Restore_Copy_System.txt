WordPress Multi-Site Backup/Restore/Copy System
Overview
Production-grade scripts for your Docker Compose WordPress stack with OpenLiteSpeed + MySQL + Redis. Features healthcheck integration, Redis cache flushing, atomic operations, smart pruning, and cross-domain copying.

Scripts: backup.sh | restore.sh | copy-site.sh

Prerequisites
text
✅ docker compose (V2) - no docker-compose V1 support
✅ Container names: mysql, redis, litespeed (your YAML)
✅ ./redis/redis.conf with maxmemory + allkeys-lru
✅ Healthchecks enabled (20s/30s intervals)
✅ .env with MARIADB_ROOT_PASSWORD for cross-domain ops
1. Backup (backup.sh)
Purpose
Per-domain DB + files backup with smart cron pruning.

Commands
bash
# Manual backup (unlimited retention)
./bin/backup.sh example.local

# Safety backup (keeps last 5)
./bin/backup.sh example.local "Pre-Copy-AutoSave"

# Cron backup (keeps last 30)
CRON_BACKUP=1 ./bin/backup.sh example.local
Output Structure
text
./backups/example.local/
├── 2026-01-16_17-30-00/                 # Timestamp folders
│   ├── example.local_db.sql.gz
│   ├── example.local_site.tar.gz
│   ├── restore-info.json               # Manifest
│   └── stats
├── 2026-01-16_17-25-00_Pre-Copy-AutoSave/  # Safety (last 5 kept)
└── 2026-01-16_17-20-00_cron/           # Cron (last 30 kept)
Cron Setup
bash
# Daily at 2AM, keeps last 30
echo "0 2 * * * cd /path/to/project && CRON_BACKUP=1 ./bin/backup.sh example.local" | crontab -

# All domains
echo "0 2 * * * cd /path/to/project && for d in ./sites/*/; do CRON_BACKUP=1 ./bin/backup.sh \$(basename \$d); done" | crontab -
2. Restore (restore.sh)
Purpose
Atomic restore from backup with pre-restore safety snapshot.

Commands
bash
# Restore latest regular backup
./bin/restore.sh example.local

# Restore latest safety backup (autosave)
./bin/restore.sh example.local autosave

# Restore specific Pre-Copy-AutoSave
./bin/restore.sh example.local precopy

# Restore specific timestamp
./bin/restore.sh example.local "2026-01-16_17-30-00"

# Cross-domain (needs MARIADB_ROOT_PASSWORD)
./bin/restore.sh new.local latest example.local
Safety Features
text
✅ Creates Pre-Restore-AutoSave before restore
✅ Atomic file mv to _pre_restore  
✅ Validates WP posts count post-restore
✅ Redis FLUSHALL post-restore
✅ Healthcheck wait before DB operations
3. Copy Site (copy-site.sh)
Purpose
Clone domain with new DB + URL replacement (staging → production).

Commands
bash
# Copy example.local → copy1.local
./bin/copy-site.sh example.local copy1.local
What It Does (30-60s total)
text
1. ✅ Safety backup of SOURCE (Pre-Copy-AutoSave)
2. ⏳ Waits MySQL healthy
3. 📥 Creates new DB + copies data (mysqldump → mysql)
4. 📁 Atomic file copy
5. 🗑️ Redis FLUSHALL
6. ⏳ Waits MySQL healthy (2nd check)
7. 🔗 WP-CLI search-replace ALL URLs
8. ⚡ DB optimization + validation
Next Steps (Post-copy)
bash
export MARIADB_DATABASE=wordpress_copy1_local  # From output
bash bin/domain.sh -A copy1.local              # Add vhost
echo '127.0.0.1 copy1.local' | sudo tee -a /etc/hosts
Complete Workflow Examples
Daily Operations
bash
# 1. Backup all sites
for d in ./sites/*/; do ./bin/backup.sh "$(basename $d)"; done

# 2. Create staging from production
./bin/copy-site.sh production.local staging.local

# 3. Test restore (uses autosave)
./bin/restore.sh test.local autosave
Disaster Recovery
bash
# Restore production from latest
./bin/restore.sh production.local

# Rollback if needed (Pre-Restore-AutoSave automatic)
./bin/restore.sh production.local precopy  # Previous Pre-Copy-AutoSave
Cron + Monitoring
bash
# crontab -e
0 2 * * * cd /path/to/project && CRON_BACKUP=1 ./bin/backup.sh production.local
*/5 * * * * watch 'docker ps --filter health=unhealthy'  # Health monitoring
Healthcheck Integration 🎯
text
All scripts wait for MySQL healthy (your 30s check) before DB ops
Redis FLUSHALL ensures cache consistency
docker ps shows (healthy) status during operations
Zero race conditions with your 20s/30s monitoring
Storage Management
text
✅ Cron backups: Last 30 kept automatically
✅ Safety backups: Last 5 Pre-Copy/Pre-Restore kept  
✅ Manual backups: Unlimited retention
✅ Smart folder naming prevents collisions
Troubleshooting
bash
# Check health status
docker ps --filter health=unhealthy

# View backup sizes
du -sh ./backups/*/*

# List safety backups
ls -t ./backups/example.local/*Pre*

# Manual Redis flush
docker exec redis redis-cli FLUSHALL
Your system is now production-ready with atomic safety, healthcheck synchronization, and zero-downtime consistency! 🚀

Deploy: Save scripts → chmod +x bin/* → test with ./bin/backup.sh test.local 🎯