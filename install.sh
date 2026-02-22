#!/bin/bash
# mac-media-stack-backup: install/uninstall scheduled backup via launchd

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

HOUR=2
UNINSTALL=false
LABEL="com.mac-media-stack.backup"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$PLIST_DIR/$LABEL.plist"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_SCRIPT="$SCRIPT_DIR/backup.sh"
MEDIA_DIR="$HOME/Media"
LOG_DIR="$MEDIA_DIR/logs"

usage() {
    echo "Usage: bash install.sh [OPTIONS]"
    echo ""
    echo "Install or remove scheduled nightly backups via launchd."
    echo ""
    echo "Options:"
    echo "  --hour HOUR      Hour to run backup (0-23, default: 2)"
    echo "  --uninstall      Remove the scheduled backup"
    echo "  --help           Show this help"
    echo ""
    echo "Examples:"
    echo "  bash install.sh              # Install nightly backup at 2am"
    echo "  bash install.sh --hour 3     # Install nightly backup at 3am"
    echo "  bash install.sh --uninstall  # Remove scheduled backup"
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hour)
            if [[ $# -lt 2 ]]; then
                echo -e "${RED}ERR${NC} Missing value for --hour"
                usage 1
            fi
            HOUR="$2"
            shift 2
            ;;
        --uninstall) UNINSTALL=true; shift ;;
        --help) usage ;;
        *) echo -e "${RED}ERR${NC} Unknown option: $1"; exit 1 ;;
    esac
done

echo ""
echo -e "${CYAN}==============================${NC}"
echo -e "${CYAN}  Mac Media Stack Backup${NC}"
echo -e "${CYAN}  LaunchD Installer${NC}"
echo -e "${CYAN}==============================${NC}"
echo ""

# ==============================
# Uninstall
# ==============================
if $UNINSTALL; then
    if launchctl list "$LABEL" &>/dev/null; then
        launchctl unload "$PLIST_PATH" 2>/dev/null || true
        echo -e "${GREEN}OK${NC}   Unloaded $LABEL"
    else
        echo -e "${YELLOW}WRN${NC}  $LABEL not currently loaded"
    fi

    if [[ -f "$PLIST_PATH" ]]; then
        rm -f "$PLIST_PATH"
        echo -e "${GREEN}OK${NC}   Removed $PLIST_PATH"
    else
        echo -e "${YELLOW}WRN${NC}  Plist not found at $PLIST_PATH"
    fi

    echo ""
    echo -e "${GREEN}Scheduled backup removed.${NC}"
    echo ""
    exit 0
fi

# ==============================
# Validate
# ==============================
if [[ ! -f "$BACKUP_SCRIPT" ]]; then
    echo -e "${RED}ERR${NC}  backup.sh not found at $BACKUP_SCRIPT"
    exit 1
fi

if ! [[ "$HOUR" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}ERR${NC}  Hour must be a whole number between 0 and 23"
    exit 1
fi

if [[ "$HOUR" -lt 0 || "$HOUR" -gt 23 ]]; then
    echo -e "${RED}ERR${NC}  Hour must be between 0 and 23"
    exit 1
fi

# ==============================
# Create directories
# ==============================
mkdir -p "$PLIST_DIR" "$LOG_DIR"

# ==============================
# Generate plist
# ==============================
echo -e "${CYAN}INF${NC}  Backup script: $BACKUP_SCRIPT"
echo -e "${CYAN}INF${NC}  Schedule: daily at ${HOUR}:00"
echo ""

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$BACKUP_SCRIPT</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>$HOUR</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/backup-launchd.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/backup-launchd-error.log</string>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
EOF

echo -e "${GREEN}OK${NC}   Created plist at $PLIST_PATH"

# ==============================
# Load
# ==============================
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"
echo -e "${GREEN}OK${NC}   Loaded $LABEL"

echo ""
echo -e "${CYAN}==============================${NC}"
echo -e "${CYAN}  Installation Complete${NC}"
echo -e "${CYAN}==============================${NC}"
echo ""
echo -e "  Schedule:  Daily at ${GREEN}${HOUR}:00${NC}"
echo -e "  Script:    $BACKUP_SCRIPT"
echo -e "  Plist:     $PLIST_PATH"
echo -e "  Logs:      $LOG_DIR/backup-launchd.log"
echo ""
echo -e "  Run ${CYAN}bash install.sh --uninstall${NC} to remove."
echo ""
