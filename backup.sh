#!/bin/bash
# mac-media-stack-backup: backup configs, databases, and compose files

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

MEDIA_DIR="$HOME/Media"
STACK_DIR="$MEDIA_DIR"
STACK_DIR_SET=false
KEEP_DAYS=14

usage() {
    echo "Usage: bash backup.sh [OPTIONS]"
    echo ""
    echo "Back up your *arr Docker stack configs, databases, and compose files."
    echo ""
    echo "Options:"
    echo "  --path DIR       Media directory (default: ~/Media)"
    echo "  --stack-dir DIR  Stack directory with docker-compose/.env (default: --path)"
    echo "  --keep DAYS      Days of backups to keep (default: 14)"
    echo "  --help         Show this help"
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --path)
            if [[ $# -lt 2 ]]; then
                echo -e "${RED}ERR${NC} Missing value for --path"
                usage 1
            fi
            MEDIA_DIR="$2"
            shift 2
            ;;
        --stack-dir)
            if [[ $# -lt 2 ]]; then
                echo -e "${RED}ERR${NC} Missing value for --stack-dir"
                usage 1
            fi
            STACK_DIR="$2"
            STACK_DIR_SET=true
            shift 2
            ;;
        --keep)
            if [[ $# -lt 2 ]]; then
                echo -e "${RED}ERR${NC} Missing value for --keep"
                usage 1
            fi
            KEEP_DAYS="$2"
            shift 2
            ;;
        --help) usage ;;
        *) echo -e "${RED}ERR${NC} Unknown option: $1"; exit 1 ;;
    esac
done

MEDIA_DIR="${MEDIA_DIR/#\~/$HOME}"
if [[ "$STACK_DIR_SET" != true ]]; then
    STACK_DIR="$MEDIA_DIR"
fi
STACK_DIR="${STACK_DIR/#\~/$HOME}"
BACKUP_DIR="$MEDIA_DIR/backups"
LOG_DIR="$MEDIA_DIR/logs"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
TEMP_DIR=$(mktemp -d)
BACKUP_NAME="backup-$TIMESTAMP"
BACKUP_STAGING="$TEMP_DIR/$BACKUP_NAME"

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

echo ""
echo -e "${CYAN}==============================${NC}"
echo -e "${CYAN}  Mac Media Stack Backup${NC}"
echo -e "${CYAN}==============================${NC}"
echo ""
echo -e "${CYAN}INF${NC}  Media directory: $MEDIA_DIR"
echo -e "${CYAN}INF${NC}  Stack directory: $STACK_DIR"
echo -e "${CYAN}INF${NC}  Timestamp: $TIMESTAMP"
echo ""

# Validate media directory
if [[ ! -d "$MEDIA_DIR" ]]; then
    echo -e "${RED}ERR${NC}  Media directory not found: $MEDIA_DIR"
    exit 1
fi

if [[ ! -d "$STACK_DIR" ]]; then
    echo -e "${RED}ERR${NC}  Stack directory not found: $STACK_DIR"
    exit 1
fi

if ! [[ "$KEEP_DAYS" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}ERR${NC}  --keep must be a whole number"
    exit 1
fi

mkdir -p "$BACKUP_DIR" "$LOG_DIR" "$BACKUP_STAGING" "$BACKUP_STAGING/configs" "$BACKUP_STAGING/databases"

# ==============================
# Config files
# ==============================
echo -e "${CYAN}--- Config Files ---${NC}"
CONFIG_COUNT=0

find "$MEDIA_DIR" -maxdepth 3 -type f \( \
    -name "config.xml" -o \
    -name "config.yml" -o \
    -name "settings.json" -o \
    -name "*.conf" \
\) ! -path "*/backups/*" ! -path "*/logs/*" 2>/dev/null | while read -r file; do
    rel_path="${file#$MEDIA_DIR/}"
    dest_dir="$BACKUP_STAGING/configs/$(dirname "$rel_path")"
    mkdir -p "$dest_dir"
    cp "$file" "$dest_dir/"
    echo -e "${GREEN}OK${NC}   Copied config: $rel_path"
done

CONFIG_COUNT=$(find "$BACKUP_STAGING/configs" -type f 2>/dev/null | wc -l | tr -d ' ')
echo -e "${GREEN}OK${NC}   $CONFIG_COUNT config file(s) found"
echo ""

# ==============================
# Databases
# ==============================
echo -e "${CYAN}--- Databases ---${NC}"

# Use sqlite online backup when available to avoid inconsistent hot copies.
backup_db_file() {
    local src="$1"
    local dst="$2"
    local rel="$3"

    if command -v sqlite3 &>/dev/null; then
        if sqlite3 "$src" ".timeout 5000" ".backup \"$dst\"" >/dev/null 2>&1; then
            echo -e "${GREEN}OK${NC}   Snapshot database: $rel"
            return 0
        fi
        echo -e "${YELLOW}WRN${NC}  sqlite3 snapshot failed for $rel, falling back to file copy"
    fi

    cp "$src" "$dst"
    echo -e "${GREEN}OK${NC}   Copied database: $rel"
}

find "$MEDIA_DIR" -maxdepth 3 -type f -name "*.db" \
    ! -path "*/backups/*" ! -path "*/logs/*" 2>/dev/null | while read -r file; do
    rel_path="${file#$MEDIA_DIR/}"
    dest_dir="$BACKUP_STAGING/databases/$(dirname "$rel_path")"
    mkdir -p "$dest_dir"
    backup_db_file "$file" "$dest_dir/$(basename "$file")" "$rel_path"
done

DB_COUNT=$(find "$BACKUP_STAGING/databases" -type f 2>/dev/null | wc -l | tr -d ' ')
echo -e "${GREEN}OK${NC}   $DB_COUNT database file(s) found"
echo ""

# ==============================
# docker-compose.yml
# ==============================
echo -e "${CYAN}--- Compose File ---${NC}"

if [[ -f "$STACK_DIR/docker-compose.yml" ]]; then
    cp "$STACK_DIR/docker-compose.yml" "$BACKUP_STAGING/"
    echo -e "${GREEN}OK${NC}   Copied docker-compose.yml"
elif [[ -f "$STACK_DIR/docker-compose.yaml" ]]; then
    cp "$STACK_DIR/docker-compose.yaml" "$BACKUP_STAGING/"
    echo -e "${GREEN}OK${NC}   Copied docker-compose.yaml"
else
    echo -e "${YELLOW}WRN${NC}  No docker-compose file found in $STACK_DIR"
fi
echo ""

# ==============================
# .env (redacted)
# ==============================
echo -e "${CYAN}--- Environment File ---${NC}"

if [[ -f "$STACK_DIR/.env" ]]; then
    grep -ivE '(password|key|secret|token)' "$STACK_DIR/.env" > "$BACKUP_STAGING/.env.redacted" 2>/dev/null || true
    REDACTED=$(grep -ciE '(password|key|secret|token)' "$STACK_DIR/.env" 2>/dev/null || echo "0")
    echo -e "${GREEN}OK${NC}   Copied .env ($REDACTED sensitive line(s) redacted)"
else
    echo -e "${YELLOW}WRN${NC}  No .env file found in $STACK_DIR"
fi
echo ""

# ==============================
# Container state
# ==============================
echo -e "${CYAN}--- Container State ---${NC}"

if command -v docker &>/dev/null; then
    COMPOSE_STATE_FILE=""
    if [[ -f "$STACK_DIR/docker-compose.yml" ]]; then
        COMPOSE_STATE_FILE="$STACK_DIR/docker-compose.yml"
    elif [[ -f "$STACK_DIR/docker-compose.yaml" ]]; then
        COMPOSE_STATE_FILE="$STACK_DIR/docker-compose.yaml"
    fi

    if [[ -n "$COMPOSE_STATE_FILE" ]] && docker compose ls &>/dev/null 2>&1; then
        if (cd "$STACK_DIR" && docker compose ps 2>/dev/null) > "$BACKUP_STAGING/container-state.txt"; then
            echo -e "${GREEN}OK${NC}   Captured container state"
        else
            echo -e "${YELLOW}WRN${NC}  Could not capture container state from $STACK_DIR"
        fi
    else
        echo -e "${YELLOW}WRN${NC}  Compose file not found or Docker Compose unavailable; skipping container state"
    fi
else
    echo -e "${YELLOW}WRN${NC}  Docker not found, skipping container state"
fi
echo ""

# ==============================
# Compress
# ==============================
echo -e "${CYAN}--- Compressing ---${NC}"

tar -czf "$BACKUP_DIR/$BACKUP_NAME.tar.gz" -C "$TEMP_DIR" "$BACKUP_NAME"
BACKUP_SIZE=$(du -sh "$BACKUP_DIR/$BACKUP_NAME.tar.gz" | cut -f1)
echo -e "${GREEN}OK${NC}   Created $BACKUP_NAME.tar.gz ($BACKUP_SIZE)"
echo ""

# ==============================
# Prune old backups
# ==============================
echo -e "${CYAN}--- Pruning Old Backups ---${NC}"

find "$BACKUP_DIR" -name "backup-*.tar.gz" -type f -mtime +"$KEEP_DAYS" 2>/dev/null | while read -r old; do
    rm -f "$old"
    echo -e "${YELLOW}DEL${NC}  Removed $(basename "$old")"
done

REMAINING=$(find "$BACKUP_DIR" -name "backup-*.tar.gz" -type f 2>/dev/null | wc -l | tr -d ' ')
echo -e "${GREEN}OK${NC}   $REMAINING backup(s) on disk (keeping $KEEP_DAYS days)"
echo ""

# ==============================
# Log
# ==============================
echo "$(date '+%Y-%m-%d %H:%M:%S') - Backup completed: $BACKUP_NAME.tar.gz ($BACKUP_SIZE)" >> "$LOG_DIR/backup.log"

# ==============================
# Summary
# ==============================
echo -e "${CYAN}==============================${NC}"
echo -e "${CYAN}  Backup Complete${NC}"
echo -e "${CYAN}==============================${NC}"
echo ""
echo -e "  Location:  ${GREEN}$BACKUP_DIR/$BACKUP_NAME.tar.gz${NC}"
echo -e "  Size:      ${GREEN}$BACKUP_SIZE${NC}"
echo -e "  Configs:   $CONFIG_COUNT"
echo -e "  Databases: $DB_COUNT"
echo -e "  Retention: $KEEP_DAYS days"
echo ""
