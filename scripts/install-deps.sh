#!/bin/bash
set -e

GREEN='\033[1;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
PURPLE='\033[1;35m'
WHITE='\033[0;37m'
NC='\033[0m'

log_info() {
    echo -e "info[$(date +'%Y-%m-%d %H:%M:%S')] |  ${WHITE}$1${NC}"
}

log_error() {
    echo -e "err[$(date +'%Y-%m-%d %H:%M:%S')]  |  ${RED}$1${NC}"
}

log_ok() {
    echo -e "ok[$(date +'%Y-%m-%d %H:%M:%S')]   |  ${GREEN}$1${NC}"
}

# Detect Postgres major version
log_info "Detecting PostgreSQL version..."
PG_VERSION_OUTPUT=$(pg_config --version)
POSTGRES_MAJOR_VERSION=$(\
    echo "$PG_VERSION_OUTPUT" | sed -E 's/^PostgreSQL ([0-9]+)\..*$/\1/'\
)
if [ -z "$POSTGRES_MAJOR_VERSION" ]; then
    log_error "Failed to detect PostgreSQL major version"
    exit 1
fi
log_ok "  - PostgreSQL version string : $PG_VERSION_OUTPUT"
log_ok "  - PostgreSQL major version  : $POSTGRES_MAJOR_VERSION"

# Install repmgr for the detected PostgreSQL version
REPMGR_PACKAGE="postgresql-${POSTGRES_MAJOR_VERSION}-repmgr"

log_info "Installing $REPMGR_PACKAGE..."
apt-get update
if ! apt-get install -y "$REPMGR_PACKAGE"; then
    log_error "Failed to install $REPMGR_PACKAGE"
    exit 1
fi
if ! command -v repmgr >/dev/null 2>&1; then
    log_error "Failed to install $REPMGR_PACKAGE"
    exit 1
fi
log_ok "Installed $(repmgr --version)"

utilities=(curl vim jq)
log_info "Installing utilities ${utilities[@]}..."
apt-get install -y "${utilities[@]}"
log_ok "Installed utilities: ${utilities[@]}"
