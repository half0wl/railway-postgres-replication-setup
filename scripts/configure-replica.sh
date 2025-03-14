#!/bin/bash
set -e

GREEN='\033[1;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
PURPLE='\033[1;35m'
WHITE='\033[0;37m'
NC='\033[0m'

DRY_RUN=false
for arg in "$@"; do
    case $arg in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
    esac
done

log_info() {
    echo -e "$(date +'%Y-%m-%d %H:%M:%S') | ${WHITE}$1${NC}"
}

log_info_hl() {
    echo -e "$(date +'%Y-%m-%d %H:%M:%S') | ${PURPLE}$1${NC}"
}

log_error() {
    echo -e "$(date +'%Y-%m-%d %H:%M:%S')  | ${RED}$1${NC}"
}

log_ok() {
    echo -e "$(date +'%Y-%m-%d %H:%M:%S') | ${GREEN}$1${NC}"
}

log_warn() {
    echo -e "$(date +'%Y-%m-%d %H:%M:%S') | ${YELLOW}$1${NC}"
}

log_dry_run() {
    echo -e "$(date +'%Y-%m-%d %H:%M:%S') | ${YELLOW}dryrun: $1${NC}"
}

confirm() {
    local prompt="$1"
    local default="$2"
    default=${default:-"Y"}
    if [ "$default" = "Y" ]; then
        echo ""
        prompt="$prompt [Y/n]: "
        echo ""
    else
        echo ""
        prompt="$prompt [y/N]: "
        echo ""
    fi
    read -r -p "$prompt" response
    if [ -z "$response" ]; then
        response=$default
    fi
    if [[ "$response" =~ ^[Yy]$ ]]; then
        return 0
    else
        return 1
    fi
}

echo ""
echo "========================================================"
echo -e "| Railway Postgres Replication Configuration - ${PURPLE}REPLICA${NC} |"
echo "========================================================"
echo ""

# Ensure required environment variables are set
REQUIRED_ENV_VARS=(\
    "RAILWAY_PROJECT_NAME" \
    "RAILWAY_SERVICE_NAME" \
    "RAILWAY_ENVIRONMENT" \
    "RAILWAY_PROJECT_ID" \
    "RAILWAY_SERVICE_ID" \
    "RAILWAY_ENVIRONMENT_ID" \
    "PGHOST" \
    "PGPORT" \
    "PRIMARY_REPMGR_USER_PASSWORD" \
    "PRIMARY_PGHOST" \
    "PRIMARY_PGPORT" \
)
for var in "${REQUIRED_ENV_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        log_error "Missing required environment variable: $var"
        log_error ""
        log_error "Please ensure you have completed the dependencies installation"
        log_error "step before running this script. Refer to:"
        log_error ""
        log_error "  https://docs.railway.com/tutorials/set-up-postgres-replication"
        log_error ""
        exit 1
    fi
done

# Ensure required commands are available
REQUIRED_COMMANDS=(\
    "pg_config" \
    "repmgr" \
    "psql" \
    "sed" \
    "grep" \
    "cat" \
)
for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "Required cmd '$cmd' not found in PATH"
        log_error ""
        log_error "Please ensure you have completed the dependencies installation"
        log_error "step before running this script. Refer to:"
        log_error ""
        log_error "  https://docs.railway.com/tutorials/set-up-postgres-replication"
        log_error ""
        exit 1
    fi
done

RAILWAY_SERVICE_URL="https://railway.app/project/${RAILWAY_PROJECT_ID}/service/${RAILWAY_SERVICE_ID}?environmentId=${RAILWAY_ENVIRONMENT_ID}"

PRIMARY_REPMGR_USER_PASSWORD_OBS="***${PRIMARY_REPMGR_USER_PASSWORD: -4}"

log_info "This script will set up repmgr and register this service as a "
log_info "replica node to your primary node."
log_info ""
log_info_hl "Before proceeding, please ensure you have read the tutorial:"
log_info ""
log_info "  https://docs.railway.com/tutorials/set-up-postgres-replication"
log_info ""
log_info_hl "You are running this script on the following Railway database:"
log_info ""
log_info "  ${RAILWAY_SERVICE_URL}"
log_info ""
log_info "  - Project        : ${RAILWAY_PROJECT_NAME}"
log_info "  - Service        : ${RAILWAY_SERVICE_NAME}"
log_info "  - Environment    : ${RAILWAY_ENVIRONMENT}"
log_info ""
log_info_hl "Using the following configuration:"
log_info ""
log_info "  - PGHOST                        : ${PGHOST}"
log_info "  - PGPORT                        : ${PGPORT}"
log_info "  - PRIMARY_PGHOST                : ${PRIMARY_PGHOST}"
log_info "  - PRIMARY_PGPORT                : ${PRIMARY_PGPORT}"
log_info "  - PRIMARY_REPMGR_USER_PASSWORD  : ${PRIMARY_REPMGR_USER_PASSWORD_OBS}"
log_info ""
log_warn "THIS SCRIPT SHOULD ONLY BE EXECUTED ON THE DATABASE YOU WISH TO "
log_warn "DESIGNATE AS THE REPLICA NODE."
log_info ""
if [ "$DRY_RUN" = true ]; then
    log_warn "--dry-run enabled. You will see a list of changes that will "
    log_warn "be made, but no changes will be applied. To apply changes, "
    log_warn "run without the --dry-run flag."
fi
confirm "This is for a REPLICA. Continue?" || {
    log_info "Exiting..."
    exit 0
}
log_info ""

# Railway Postgres template mounts the volume at `/var/lib/postgresql/data`,
# so we're going to use that for persistence (binaries, repmgr config, etc.)
# The actual pgdata path is `/var/lib/postgresql/data/pgdata`.
RAILWAY_VOL_MOUNT_PATH="/var/lib/postgresql/data"
PGDATA_DIR="$RAILWAY_VOL_MOUNT_PATH/pgdata"

# Ensure PostgreSQL data directory exists
if [ ! -d "$PGDATA_DIR" ]; then
    log_error "PostgreSQL data directory '$PGDATA_DIR' not found"
    exit 1
fi
log_ok "Found PostgreSQL data directory at '$PGDATA_DIR'"

# Ensure PostgreSQL configuration file exists
POSTGRESQL_CONF="$PGDATA_DIR/postgresql.conf"
if [ ! -f "$POSTGRESQL_CONF" ]; then
    log_error "PostgreSQL configuration file '$POSTGRESQL_CONF' not found"
    exit 1
fi
log_ok "Found PostgreSQL configuration file at '$POSTGRESQL_CONF'"

# Create Railway runtime dir
RAILWAY_RUNTIME_DIR="$RAILWAY_VOL_MOUNT_PATH/railway-runtime"
REPMGR_DIR="$RAILWAY_RUNTIME_DIR/repmgr"
REPMGR_CONF="$REPMGR_DIR/repmgr.conf"

if [ "$DRY_RUN" = true ]; then
    # 0. Create Railway runtime directory
    log_dry_run "create directory '$RAILWAY_RUNTIME_DIR' with:"
    log_dry_run ""
    log_dry_run "  mkdir -p '$RAILWAY_RUNTIME_DIR'"
    log_dry_run ""

    # 1. Create repmgr directory
    log_dry_run "create directory '$REPMGR_DIR' with:"
    log_dry_run ""
    log_dry_run "  mkdir -p '$REPMGR_DIR'"
    log_dry_run ""

    # 2. Create repmgr configuration file
    log_dry_run "create '$REPMGR_CONF' with content:"
    log_dry_run ""
    log_dry_run "  node_id=2"
    log_dry_run "  node_name='node2'"
    log_dry_run "  conninfo='host=${PGHOST} port=${PGPORT} user=repmgr dbname=repmgr connect_timeout=10'"
    log_dry_run "  data_directory='${PGDATA_DIR}'"
    log_dry_run ""

    # 3. Perform clone
    log_dry_run "perform clone of primary node with:"
    log_dry_run ""
    log_dry_run "  export PGPASSWORD=\"$PRIMARY_REPMGR_USER_PASSWORD_OBS\""
    log_dry_run "  su -m postgres -c \"repmgr -h $PRIMARY_PGHOST -p $PRIMARY_PGPORT -u repmgr -f $REPMGR_CONF standby clone --dry-run\""
    log_dry_run ""

    # 4. Finish
    log_warn ""
    log_warn "✅ Configuration complete in --dry-run mode. No changes were made"
    log_warn "📢 To apply changes, run without the --dry-run flag"
    echo ""
# -----------------------------------------------------------------------------
# dryrun end
# -----------------------------------------------------------------------------
else
# -----------------------------------------------------------------------------
# normal run start
# -----------------------------------------------------------------------------
    # 0. Create Railway runtime directory
    if [ ! -d "$RAILWAY_RUNTIME_DIR" ]; then
        mkdir -p "$RAILWAY_RUNTIME_DIR"
    fi

    # 1. Create repmgr directory
    log_info "Setting up repmgr configuration..."
    if [ ! -d "$REPMGR_DIR" ]; then
        mkdir -p "$REPMGR_DIR"
    fi

    # 2. Create repmgr configuration file
    cat > "$REPMGR_CONF" << EOF
node_id=2
node_name='node2'
conninfo='host=${PGHOST} port=${PGPORT} user=repmgr dbname=repmgr connect_timeout=10'
data_directory='${PGDATA_DIR}'
EOF
    chown postgres:postgres "$REPMGR_CONF"
    chmod 600 "$REPMGR_CONF"
    log_ok "Created repmgr configuration at '$REPMGR_CONF'"

    # 3. Perform clone
    log_info "Performing clone of primary node..."
    export PGPASSWORD="$PRIMARY_REPMGR_USER_PASSWORD"
    if su -m postgres -c \
        "repmgr -h $PRIMARY_PGHOST -p $PRIMARY_PGPORT -u repmgr -f $REPMGR_CONF standby clone --dry-run"; then
            log_ok "Successfully cloned primary node"
    else
        log_error "Failed to clone primary node"
        exit 1
    fi

    # 4. Finish
    log_ok ""
    log_ok "✅ Configuration complete"
    log_ok "🚀 Please re-deploy your Postgres service at:"
    log_ok "  ${RAILWAY_SERVICE_URL} "
    log_ok "for changes to take effect."
    echo ""
fi
