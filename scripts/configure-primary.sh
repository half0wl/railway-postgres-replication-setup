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
    echo -e "info[$(date +'%Y-%m-%d %H:%M:%S')] |  ${WHITE}$1${NC}"
}

log_info_hl() {
    echo -e "info[$(date +'%Y-%m-%d %H:%M:%S')] |  ${PURPLE}$1${NC}"
}

log_error() {
    echo -e "err[$(date +'%Y-%m-%d %H:%M:%S')]  |  ${RED}$1${NC}"
}

log_ok() {
    echo -e "ok[$(date +'%Y-%m-%d %H:%M:%S')]   |  ${GREEN}$1${NC}"
}

log_warn() {
    echo -e "warn[$(date +'%Y-%m-%d %H:%M:%S')] |  ${YELLOW}$1${NC}"
}

log_dry_run() {
    echo -e "info[$(date +'%Y-%m-%d %H:%M:%S')] |  ${YELLOW}dryrun: $1${NC}"
}

confirm() {
    local prompt="$1"
    local default="$2"
    default=${default:-"Y"}
    if [ "$default" = "Y" ]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
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

REQUIRED_ENV_VARS=(\
    "RAILWAY_PROJECT_NAME" \
    "RAILWAY_SERVICE_NAME" \
    "RAILWAY_ENVIRONMENT" \
    "RAILWAY_PROJECT_ID" \
    "RAILWAY_SERVICE_ID" \
    "RAILWAY_ENVIRONMENT_ID" \
    "PGHOST" \
    "PGPORT" \
    "REPMGR_USER_PASSWORD" \
)
for var in "${REQUIRED_ENV_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        log_error "Missing required environment variable: $var"
        exit 1
    fi
done

RAILWAY_SERVICE_URL="https://railway.app/project/${RAILWAY_PROJECT_ID}/service/${RAILWAY_SERVICE_ID}?environmentId=${RAILWAY_ENVIRONMENT_ID}"

log_info "--------------------------------------------------------------------"
log_info_hl "|        Railway PostgreSQL Replication Configuration Script              |"
log_info "--------------------------------------------------------------------"
log_info ""
log_info_hl "Before proceeding, please ensure you have read the documentation:"
log_info ""
log_info "  https://docs.railway.com/tutorials/set-up-postgres-replication"
log_info ""
log_info_hl "You are running this script the following Railway database:"
log_info ""
log_info "  - Project       : ${RAILWAY_PROJECT_NAME}"
log_info "  - Service       : ${RAILWAY_SERVICE_NAME}"
log_info "  - Environment   : ${RAILWAY_ENVIRONMENT}"
log_info "  - URL           : ${RAILWAY_SERVICE_URL}"
log_info "  - PGHOST/PGPORT : ${PGHOST} / ${PGPORT}"
log_info ""
log_info_hl "THIS SCRIPT SHOULD ONLY BE EXECUTED ON THE DATABASE YOU WISH TO "
log_info_hl "DESIGNATE AS THE PRIMARY NODE."
log_info ""
log_info_hl "  - This script will make changes to your current PostgreSQL "
log_info_hl "    configuration and set up repmgr"
log_info_hl ""
log_info_hl "  - A re-deploy of your database is required for changes to take "
log_info_hl "    effect after configuration is finished"
log_info_hl ""
log_info_hl "  - Please ensure you have a backup of your data before proceeding"
log_info_hl "    Refer to https://docs.railway.com/reference/backups for more"
log_info_hl "    information on how to create backups"
log_info ""
if [ "$DRY_RUN" = true ]; then
    log_warn "--dry-run enabled. You will see a list of changes that will "
    log_warn "be applied, but no changes will be made. To apply changes, "
    log_warn "run without the --dry-run flag."
fi
confirm "Continue?" || {
    log_info "Exiting..."
    exit 0
}
log_info ""

REQUIRED_COMMANDS=(\
    "foobar" \
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
        log_error "Please ensure you have completed the dependencies"
        log_error "installation step before running this script."
        log_error ""
        log_error "https://docs.railway.com/tutorials/set-up-postgres-replication"
        exit 1
    fi
done

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
RAILWAY_RUNTIME_DIR="$RAILWAY_VOL_MOUNT_PATH/railway-runtime/"
if [ $DRY_RUN = true ]; then
    log_dry_run "create directory '$RAILWAY_RUNTIME_DIR'"
else
    if [ ! -d "$RAILWAY_RUNTIME_DIR" ]; then
        mkdir -p "$RAILWAY_RUNTIME_DIR"
    fi
fi

# Create replication configuration. If there's an existing replication conf,
# do nothing
if grep -q \
    "include 'postgresql.replication.conf'" "$POSTGRESQL_CONF" 2>/dev/null; then
        log_error "Include directive already exists in '$POSTGRESQL_CONF'. This"
        log_error "script should only be ran once."
    exit 1
fi

POSTGRESQL_CONF_BAK="$PGDATA_DIR/postgresql.bak.conf"
REPLICATION_CONF="$PGDATA_DIR/postgresql.replication.conf"
REPMGR_DIR="$RAILWAY_RUNTIME_DIR/repmgr"
REPMGR_CONF="$REPMGR_DIR/repmgr.conf"

if [ "$DRY_RUN" = true ]; then
    # 1. Create the replication configuration file
    log_dry_run "create file '$REPLICATION_CONF' with content:"
    log_dry_run ""
    log_dry_run "  max_wal_senders = 10"
    log_dry_run "  max_replication_slots = 10"
    log_dry_run "  wal_level = replica"
    log_dry_run "  wal_log_hints = on"
    log_dry_run "  hot_standby = on"
    log_dry_run "  archive_mode = on"
    log_dry_run "  archive_command = '/bin/true'"
    log_dry_run ""

    # 2. Backup the original postgresql.conf file
    log_dry_run "back up '$POSTGRESQL_CONF' to '$POSTGRESQL_CONF_BAK'"
    log_dry_run ""

    # 3. Add the include directive to postgresql.conf
    log_dry_run "append to '$POSTGRESQL_CONF' this line:"
    log_dry_run ""
    log_dry_run "  # Added by Railway on $(date +'%Y-%m-%d %H:%M:%S')"
    log_dry_run "  include 'postgresql.replication.conf'"
    log_dry_run ""

    # 4. Create repmgr user and database
    log_dry_run "execute the following psql commands:"
    log_dry_run ""
    log_dry_run "  CREATE USER repmgr WITH SUPERUSER PASSWORD '${REPMGR_USER_PASSWORD}';"
    log_dry_run "  CREATE DATABASE repmgr;"
    log_dry_run "  GRANT ALL PRIVILEGES ON DATABASE repmgr TO repmgr;"
    log_dry_run "  ALTER USER repmgr SET search_path TO repmgr, railway, public;"
    log_dry_run ""

    # 5. Create repmgr directory
    log_dry_run "create directory '$REPMGR_DIR'"
    log_dry_run ""

    # 6. Create repmgr configuration file
    log_dry_run "create '$REPMGR_CONF' with content:"
    log_dry_run ""
    log_dry_run "  node_id=1"
    log_dry_run "  node_name='node1'"
    log_dry_run "  conninfo='host=${PGHOST} port=${PGPORT} user=repmgr dbname=repmgr connect_timeout=10'"
    log_dry_run "  data_directory='${PGDATA_DIR}'"
    log_dry_run ""

    # 7. Register primary node
    log_dry_run "register primary node with:"
    log_dry_run ""
    log_dry_run "  su -m postgres -c \"repmgr -f $REPMGR_CONF primary register\""
else

    # 1. Create the replication configuration file
    log_info "Creating replication configuration file at '$REPLICATION_CONF'"
    cat > "$REPLICATION_CONF" << EOF
max_wal_senders = 10
max_replication_slots = 10
wal_level = replica
wal_log_hints = on
hot_standby = on
archive_mode = on
archive_command = '/bin/true'
EOF

    # 2. Backup the original postgresql.conf file
    log_info "Backing up '$POSTGRESQL_CONF' to '$POSTGRESQL_CONF_BAK'"
    cp "$POSTGRESQL_CONF" "$POSTGRESQL_CONF_BAK"
    log_ok "Created backup of PostgreSQL configuration at '$POSTGRESQL_CONF_BAK'"

    # 3. Add the include directive to postgresql.conf
    echo "" >> "$POSTGRESQL_CONF"
    echo "# Added by Railway on $(date +'%Y-%m-%d %H:%M:%S')" >> "$POSTGRESQL_CONF"
    echo "include 'postgresql.replication.conf'" >> "$POSTGRESQL_CONF"
    log_ok "Added include directive to '$POSTGRESQL_CONF'"

    # 4. Create repmgr user and database
    log_info "Creating repmgr user and database..."
    if ! psql -c "SELECT 1 FROM pg_roles WHERE rolname='repmgr'" | grep -q 1; then
        psql -c "CREATE USER repmgr WITH SUPERUSER PASSWORD '${REPMGR_USER_PASSWORD}';"
        log_ok "Created repmgr user"
    else
        log_info "User repmgr already exists"
    fi

    if ! psql -c "SELECT 1 FROM pg_database WHERE datname='repmgr'" | grep -q 1; then
        psql -c "CREATE DATABASE repmgr;"
        log_ok "Created repmgr database"
    else
        log_info "Database repmgr already exists"
    fi

    psql -c "GRANT ALL PRIVILEGES ON DATABASE repmgr TO repmgr;"
    psql -c "ALTER USER repmgr SET search_path TO repmgr, railway, public;"
    log_ok "Configured repmgr user and database permissions"

    # 5. Create repmgr directory and copy binary
    log_info "Setting up repmgr configuration and binary..."
    if [ ! -d "$REPMGR_DIR" ]; then
        mkdir -p "$REPMGR_DIR"
    fi
    REPMGR_SRC_PATH=$(command -v repmgr)
    if [ -z "$REPMGR_SRC_PATH" ]; then
        log_error "Cannot find repmgr binary"
        exit 1
    fi

    # 6. Create repmgr configuration file
    cat > "$REPMGR_CONF" << EOF
node_id=1
node_name='node1'
conninfo='host=${PGHOST} port=${PGPORT} user=repmgr dbname=repmgr connect_timeout=10'
data_directory='${PGDATA_DIR}'
EOF
    chown postgres:postgres "$REPMGR_CONF"
    chmod 600 "$REPMGR_CONF"
    log_ok "Created repmgr configuration at '$REPMGR_CONF'"

    # 7. Register primary node
    log_info "Registering primary node with repmgr..."
    export PGPASSWORD="$REPMGR_USER_PASSWORD"
    if su -m postgres -c "repmgr -f $REPMGR_CONF primary register"; then
        log_ok "Successfully registered primary node"
    else
        log_error "Failed to register primary node with repmgr"
        exit 1
    fi
fi

if [ "$DRY_RUN" = true ]; then
    log_warn ""
    log_warn "✅ Configuration complete in --dry-run mode. No changes were made"
    log_warn "📢 To apply changes, run without the --dry-run flag"
    log_warn ""
else
    log_ok ""
    log_ok "✅ Configuration complete"
    log_ok "🚀 Please re-deploy your Postgres service at:"
    log_ok "  ${RAILWAY_SERVICE_URL} "
    log_ok "for changes to take effect."
    log_ok ""
fi
