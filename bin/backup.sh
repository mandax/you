#!/bin/bash
# =============================================================================
# You IAM — backup script (template)
# =============================================================================
#
# Creates a consistent SQLite snapshot (zero downtime) via `.backup`,
# archives it with audit logs, uploads to an rclone remote,
# and prunes old backups.
#
# Usage:
#   # Use defaults (requires DATABASE_PATH to be set or the defaults to match)
#   ./bin/backup.sh
#
#   # Override paths
#   DATABASE_PATH=/data/you/prod.db \
#     AUDIT_LOG_DIR=/var/log/you \
#     BACKUP_DIR=/srv/backups \
#     RETENTION_DAYS=14 \
#     ./bin/backup.sh
#
# Schedule (cron):
#   0 3 * * * cd /home/you/you && ./bin/backup.sh >> /var/log/you/backup.log 2>&1
#
# Dependencies:
#   - sqlite3  (included with SQLite)
#   - rclone   (https://rclone.org) with a configured remote (set RCLONE_REMOTE)
# =============================================================================

set -uo pipefail

# ---- Configuration (override via environment variables) ----
DATABASE_PATH="${DATABASE_PATH:-/data/you/prod.db}"
AUDIT_LOG_DIR="${AUDIT_LOG_DIR:-/var/log/you}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/backups/you}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"

# ---- Derived ----
DATE=$(date +%Y-%m-%d)
BACKUP_FILE="$BACKUP_DIR/you-$DATE.tar.gz"
WORK_DIR=$(mktemp -d "/tmp/you-backup-XXXXXX")
RCLONE_REMOTE="${RCLONE_REMOTE:-}"
RCLONE_PATH="${RCLONE_PATH:-backups/you}"

# ---- Cleanup handler ----
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# ---- Pre-flight checks ----
echo "[$DATE] Starting You backup..."

mkdir -p "$BACKUP_DIR"

if [ ! -f "$DATABASE_PATH" ]; then
  echo "[$DATE] ERROR: Database not found at $DATABASE_PATH" >&2
  exit 1
fi

if ! command -v sqlite3 &>/dev/null; then
  echo "[$DATE] ERROR: sqlite3 not found. Install it and try again." >&2
  exit 1
fi

# ---- 1. Database snapshot (zero-downtime) ----
echo "[$DATE] Creating database snapshot..."
if sqlite3 "$DATABASE_PATH" ".backup $WORK_DIR/you.db"; then
  echo "[$DATE]   ✓ Database snapshot saved"
else
  echo "[$DATE]   ✗ Database backup failed!" >&2
  exit 1
fi

# ---- 2. Audit logs (append-only JSONL, safe to copy) ----
if [ -d "$AUDIT_LOG_DIR" ]; then
  echo "[$DATE] Copying audit logs..."
  mkdir -p "$WORK_DIR/logs"
  cp -r "$AUDIT_LOG_DIR/." "$WORK_DIR/logs/"
  echo "[$DATE]   ✓ Audit logs copied ($(find "$AUDIT_LOG_DIR" -name '*.jsonl' 2>/dev/null | wc -l) files)"
else
  echo "[$DATE]   - Audit log directory $AUDIT_LOG_DIR not found, skipping"
fi

# ---- 3. Archive ----
echo "[$DATE] Archiving..."
if tar czf "$BACKUP_FILE" -C "$WORK_DIR" .; then
  echo "[$DATE]   ✓ Backup saved to $BACKUP_FILE"
  echo "[$DATE]   Size: $(du -h "$BACKUP_FILE" | cut -f1)"
else
  echo "[$DATE]   ✗ Archive failed!" >&2
  exit 1
fi

# ---- 4. Upload via rclone ----
if [ -n "$RCLONE_REMOTE" ] && command -v rclone &>/dev/null && rclone listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE}:"; then
  echo "[$DATE] Uploading to ${RCLONE_REMOTE}:${RCLONE_PATH}/..."
  if rclone copy "$BACKUP_FILE" "${RCLONE_REMOTE}:${RCLONE_PATH}/"; then
    echo "[$DATE]   ✓ Upload complete"
  else
    echo "[$DATE]   ✗ Upload failed — backup remains locally at $BACKUP_FILE" >&2
  fi
else
  echo "[$DATE]   - rclone remote not configured, skipping upload"
  echo "[$DATE]   - Set RCLONE_REMOTE to a configured rclone remote to enable uploads"
  echo "[$DATE]   - Backup remains locally at $BACKUP_FILE"
fi

# ---- 5. Prune old backups ----
echo "[$DATE] Pruning backups older than $RETENTION_DAYS days..."
DELETED=$(find "$BACKUP_DIR" -maxdepth 1 -name "you-*.tar.gz" -mtime +"$RETENTION_DAYS" -print -delete 2>/dev/null | wc -l)
echo "[$DATE]   ✓ Removed $DELETED old backup(s), keeping last $RETENTION_DAYS days"

echo "[$DATE] Backup complete. Total time: $(ps -o etime= -p $$ | tr -d ' ')"
