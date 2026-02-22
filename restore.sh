#!/bin/bash
# mac-media-stack-backup: restore configs, databases, and compose files from backup

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

MEDIA_DIR="$HOME/Media"
STACK_DIR="$MEDIA_DIR"
STACK_DIR_SET=false
LIST_MODE=false
LATEST_MODE=false
BACKUP_TARGET=""

usage() {
    echo "Usage: bash restore.sh [OPTIONS] [BACKUP_NAME]"
    echo ""
    echo "Restore your *arr Docker stack from a backup."
    echo ""
    echo "Options:"
    echo "  --list         List available backups"
    echo "  --latest       Restore the most recent backup"
    echo "  --path DIR     Media directory (default: ~/Media)"
    echo "  --stack-dir DIR  Stack directory with docker-compose/.env (default: --path)"
    echo "  --help         Show this help"
    echo ""
    echo "Examples:"
    echo "  bash restore.sh --list"
    echo "  bash restore.sh --latest"
    echo "  bash restore.sh 20260222-020000"
    echo "  bash restore.sh backup-20260222-020000.tar.gz"
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list) LIST_MODE=true; shift ;;
        --latest) LATEST_MODE=true; shift ;;
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
        --help) usage ;;
        -*) echo -e "${RED}ERR${NC} Unknown option: $1"; exit 1 ;;
        *) BACKUP_TARGET="$1"; shift ;;
    esac
done

MEDIA_DIR="${MEDIA_DIR/#\~/$HOME}"
if [[ "$STACK_DIR_SET" != true ]]; then
    STACK_DIR="$MEDIA_DIR"
fi
STACK_DIR="${STACK_DIR/#\~/$HOME}"
BACKUP_DIR="$MEDIA_DIR/backups"

if [[ ! -d "$BACKUP_DIR" ]]; then
    echo -e "${RED}ERR${NC}  Backup directory not found: $BACKUP_DIR"
    exit 1
fi

# ==============================
# List mode
# ==============================
if $LIST_MODE; then
    echo ""
    echo -e "${CYAN}==============================${NC}"
    echo -e "${CYAN}  Available Backups${NC}"
    echo -e "${CYAN}==============================${NC}"
    echo ""

    FOUND=0
    while IFS= read -r f; do
        name=$(basename "$f")
        size=$(du -sh "$f" | cut -f1)
        date_part=$(echo "$name" | sed 's/backup-\([0-9]*\)-\([0-9]*\).*/\1/')
        time_part=$(echo "$name" | sed 's/backup-[0-9]*-\([0-9]*\).*/\1/')
        formatted_date="${date_part:0:4}-${date_part:4:2}-${date_part:6:2} ${time_part:0:2}:${time_part:2:2}:${time_part:4:2}"
        echo -e "  ${GREEN}$name${NC}  ($size)  $formatted_date"
        FOUND=$((FOUND + 1))
    done < <(ls -1t "$BACKUP_DIR"/backup-*.tar.gz 2>/dev/null)

    if [[ $FOUND -eq 0 ]]; then
        echo -e "  ${YELLOW}No backups found${NC}"
    fi
    echo ""
    exit 0
fi

# ==============================
# Resolve backup file
# ==============================
BACKUP_FILE=""

if $LATEST_MODE; then
    BACKUP_FILE=$(ls -t "$BACKUP_DIR"/backup-*.tar.gz 2>/dev/null | head -1)
    if [[ -z "$BACKUP_FILE" ]]; then
        echo -e "${RED}ERR${NC}  No backups found in $BACKUP_DIR"
        exit 1
    fi
elif [[ -n "$BACKUP_TARGET" ]]; then
    # Try exact path first
    if [[ -f "$BACKUP_TARGET" ]]; then
        BACKUP_FILE="$BACKUP_TARGET"
    elif [[ -f "$BACKUP_DIR/$BACKUP_TARGET" ]]; then
        BACKUP_FILE="$BACKUP_DIR/$BACKUP_TARGET"
    elif [[ -f "$BACKUP_DIR/backup-$BACKUP_TARGET.tar.gz" ]]; then
        BACKUP_FILE="$BACKUP_DIR/backup-$BACKUP_TARGET.tar.gz"
    else
        echo -e "${RED}ERR${NC}  Backup not found: $BACKUP_TARGET"
        echo "    Tried:"
        echo "      $BACKUP_TARGET"
        echo "      $BACKUP_DIR/$BACKUP_TARGET"
        echo "      $BACKUP_DIR/backup-$BACKUP_TARGET.tar.gz"
        exit 1
    fi
else
    echo -e "${RED}ERR${NC}  No backup specified. Use --latest, --list, or provide a backup name."
    echo "    Run 'bash restore.sh --help' for usage."
    exit 1
fi

echo ""
echo -e "${CYAN}==============================${NC}"
echo -e "${CYAN}  Mac Media Stack Restore${NC}"
echo -e "${CYAN}==============================${NC}"
echo ""
echo -e "${CYAN}INF${NC}  Backup: $(basename "$BACKUP_FILE")"
echo -e "${CYAN}INF${NC}  Media directory: $MEDIA_DIR"
echo -e "${CYAN}INF${NC}  Stack directory: $STACK_DIR"
echo ""

# Confirm
echo -e "${YELLOW}WRN${NC}  This will overwrite existing configs and databases."
read -rp "    Continue? (y/N) " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo -e "${RED}ERR${NC}  Restore cancelled."
    exit 1
fi
echo ""

TEMP_DIR=$(mktemp -d)
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# ==============================
# Extract
# ==============================
echo -e "${CYAN}--- Extracting ---${NC}"
tar -xzf "$BACKUP_FILE" -C "$TEMP_DIR"
BACKUP_ROOT=$(find "$TEMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)
if [[ -z "$BACKUP_ROOT" || ! -d "$BACKUP_ROOT" ]]; then
    echo -e "${RED}ERR${NC}  Backup archive did not contain a valid root directory"
    exit 1
fi
EXTRACTED="$BACKUP_ROOT"
echo -e "${GREEN}OK${NC}   Extracted to temp directory"
echo ""

# ==============================
# Stop containers
# ==============================
echo -e "${CYAN}--- Stopping Containers ---${NC}"

STOP_COMPOSE_FILE=""
if [[ -f "$STACK_DIR/docker-compose.yml" ]]; then
    STOP_COMPOSE_FILE="$STACK_DIR/docker-compose.yml"
elif [[ -f "$STACK_DIR/docker-compose.yaml" ]]; then
    STOP_COMPOSE_FILE="$STACK_DIR/docker-compose.yaml"
fi

if command -v docker &>/dev/null && [[ -n "$STOP_COMPOSE_FILE" ]]; then
    if (cd "$STACK_DIR" && docker compose stop >/dev/null 2>&1); then
        echo -e "${GREEN}OK${NC}   Containers stopped"
    else
        echo -e "${YELLOW}WRN${NC}  Failed to stop containers cleanly, continuing restore"
    fi
else
    echo -e "${YELLOW}WRN${NC}  No compose file or Docker not found, skipping container stop"
fi
echo ""

# ==============================
# Restore configs
# ==============================
echo -e "${CYAN}--- Restoring Configs ---${NC}"
CONFIG_COUNT=0

if [[ -d "$EXTRACTED/configs" ]]; then
    find "$EXTRACTED/configs" -type f 2>/dev/null | while read -r file; do
        rel_path="${file#$EXTRACTED/configs/}"
        dest="$MEDIA_DIR/$rel_path"
        mkdir -p "$(dirname "$dest")"
        cp "$file" "$dest"
        echo -e "${GREEN}OK${NC}   Restored: $rel_path"
    done
    CONFIG_COUNT=$(find "$EXTRACTED/configs" -type f 2>/dev/null | wc -l | tr -d ' ')
else
    echo -e "${YELLOW}WRN${NC}  No configs in backup"
fi
echo -e "${GREEN}OK${NC}   $CONFIG_COUNT config file(s) restored"
echo ""

# ==============================
# Restore databases
# ==============================
echo -e "${CYAN}--- Restoring Databases ---${NC}"
DB_COUNT=0

if [[ -d "$EXTRACTED/databases" ]]; then
    find "$EXTRACTED/databases" -type f 2>/dev/null | while read -r file; do
        rel_path="${file#$EXTRACTED/databases/}"
        dest="$MEDIA_DIR/$rel_path"
        mkdir -p "$(dirname "$dest")"
        cp "$file" "$dest"
        echo -e "${GREEN}OK${NC}   Restored: $rel_path"
    done
    DB_COUNT=$(find "$EXTRACTED/databases" -type f 2>/dev/null | wc -l | tr -d ' ')
else
    echo -e "${YELLOW}WRN${NC}  No databases in backup"
fi
echo -e "${GREEN}OK${NC}   $DB_COUNT database file(s) restored"
echo ""

# ==============================
# Restore docker-compose
# ==============================
echo -e "${CYAN}--- Restoring Compose File ---${NC}"

if [[ -f "$EXTRACTED/docker-compose.yml" ]]; then
    mkdir -p "$STACK_DIR"
    cp "$EXTRACTED/docker-compose.yml" "$STACK_DIR/"
    echo -e "${GREEN}OK${NC}   Restored docker-compose.yml"
elif [[ -f "$EXTRACTED/docker-compose.yaml" ]]; then
    mkdir -p "$STACK_DIR"
    cp "$EXTRACTED/docker-compose.yaml" "$STACK_DIR/"
    echo -e "${GREEN}OK${NC}   Restored docker-compose.yaml"
else
    echo -e "${YELLOW}WRN${NC}  No compose file in backup"
fi
echo ""

# ==============================
# .env warning
# ==============================
echo -e "${CYAN}--- Environment File ---${NC}"

if [[ -f "$EXTRACTED/.env.redacted" ]]; then
    echo -e "${YELLOW}WRN${NC}  Backup contains a REDACTED .env file."
    echo -e "${YELLOW}WRN${NC}  Sensitive values (passwords, keys, tokens) were stripped during backup."
    echo -e "${YELLOW}WRN${NC}  Check your .env file and re-add any secrets manually."
    mkdir -p "$STACK_DIR"
    cp "$EXTRACTED/.env.redacted" "$STACK_DIR/.env.redacted"
    echo -e "${GREEN}OK${NC}   Saved .env.redacted for reference"
else
    echo -e "${CYAN}INF${NC}  No .env in backup"
fi
echo ""

# ==============================
# Restart containers
# ==============================
echo -e "${CYAN}--- Restarting Containers ---${NC}"

START_COMPOSE_FILE=""
if [[ -f "$STACK_DIR/docker-compose.yml" ]]; then
    START_COMPOSE_FILE="$STACK_DIR/docker-compose.yml"
elif [[ -f "$STACK_DIR/docker-compose.yaml" ]]; then
    START_COMPOSE_FILE="$STACK_DIR/docker-compose.yaml"
fi

if command -v docker &>/dev/null && [[ -n "$START_COMPOSE_FILE" ]]; then
    if (cd "$STACK_DIR" && docker compose up -d >/dev/null 2>&1); then
        echo -e "${GREEN}OK${NC}   Containers started"
        echo ""

        # Health check
        echo -e "${CYAN}--- Health Check ---${NC}"
        sleep 3
        (cd "$STACK_DIR" && docker compose ps 2>/dev/null) || true
    else
        echo -e "${RED}ERR${NC}  Restore completed, but container restart failed."
        echo -e "${RED}ERR${NC}  Check compose syntax/secrets and run: (cd \"$STACK_DIR\" && docker compose up -d)"
        exit 1
    fi
else
    echo -e "${YELLOW}WRN${NC}  No compose file or Docker not found, skipping restart"
fi
echo ""

# ==============================
# Summary
# ==============================
echo -e "${CYAN}==============================${NC}"
echo -e "${CYAN}  Restore Complete${NC}"
echo -e "${CYAN}==============================${NC}"
echo ""
echo -e "  Backup:    $(basename "$BACKUP_FILE")"
echo -e "  Configs:   $CONFIG_COUNT"
echo -e "  Databases: $DB_COUNT"
echo ""
echo -e "${YELLOW}Reminder: Check your .env file for any missing secrets.${NC}"
echo ""
