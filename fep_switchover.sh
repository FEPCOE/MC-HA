#!/usr/bin/env bash
# =============================================================================
#  fep_switchover.sh — Planned switchover (role swap) for Fujitsu Enterprise Postgres streaming replication.
#  Author: Kothari Nishchay
#
#  What this does:
#   1) Confirms both servers are reachable and roles are correct (primary vs standby).
#   2) Waits until the standby has replayed the primary's WAL up to LAG_WAIT_BYTES.
#   3) Promotes the standby so it becomes the NEW PRIMARY.
#   4) Immediately stops the old primary (fencing) to avoid split-brain.
#   5) (Optional) Creates/ensures a physical replication slot on the NEW PRIMARY.
#   6) Rewinds the old primary onto the NEW PRIMARY's timeline (pg_rewind).
#   7) Reconfigures the old primary as a standby following the NEW PRIMARY.
#   8) Starts the new standby and (optionally) verifies replication appears on the NEW PRIMARY.
#   9) Post tasks: CHECKPOINT on NEW PRIMARY, set synchronous_standby_names, refresh MC (--mc-only).
#
#  Works with: Fujitsu Enterprise Postgres 12+ (uses standby.signal & pg_promote), Linux.
#
# -----------------------------------------------------------------------------
#  PRE-REQUISITES
# -----------------------------------------------------------------------------
#  1. OS-Level Passwordless SSH (MANDATORY)
#     - The OS user (typically 'fsepuser') must have key-based SSH access
#       between the controller host and both Fujitsu Enterprise Postgres nodes.
#     - The script runs remote commands (pg_ctl, pg_rewind, file edits, etc.)
#       using SSH — no passwords are prompted by default.
#     - This ensures smooth, non-interactive execution during failover or switchover.
#
#  2. Fujitsu Enterprise Postgres binaries accessible on both nodes:
#        - pg_ctl, pg_rewind, psql
#        - Adjust PG_CTL / PG_REWIND paths below if not in default PATH.
#
#  3. The REPL_USER must have REPLICATION + LOGIN privilege.
#     (Used for read-only SQL checks and slot management.)
#
#  4. If Fujitsu Enterprise Postgres is managed by systemd, the 'fsepuser' must be allowed
#     passwordless sudo for:
#         sudo systemctl start/stop fep@...
#
#  5. Mirroring Controller (MC) optional but supported.
#     If MC is in use, MC_CTL path must be valid, and '--mc-only' refresh
#     will stop/start MC services gracefully after role swap.
#
# -----------------------------------------------------------------------------
#  NOTE:
#    - pg_rewind is run with PGOPTIONS='-c jit=off' to avoid JIT dependencies.
#    - No modification is made to jit_provider or database settings.
#    - All SSH operations run in BatchMode (non-interactive) by default.
#    - ALLOW_SSH_PASSWORD=1 can be used for testing only (not recommended).
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# =========================
# CONFIG — EDIT THESE
# =========================
# These parameters describe where the current PRIMARY and STANDBY are and how to reach them.

# Current PRIMARY (this will be stopped and rejoined as standby)
PRIMARY_HOST="10.1.0.21"           # TCP address used by psql. Adjust accodring to your environment
PRIMARY_SSH_HOST="10.1.0.21"       # SSH target for OS commands. Adjust accodring to your environment
PRIMARY_SSH_USER="fsepuser"        # SSH user on current primary. Adjust accodring to your environment
PRIMARY_PGDATA="/database/inst1"   # PGDATA on current primary. Adjust accodring to your environment
PRIMARY_PORT=27500                 # Fujitsu Enterprise Postgres port on current primary. Adjust accodring to your environment

# Current STANDBY (this will be promoted to NEW PRIMARY)
STANDBY_HOST="10.1.0.20"           # TCP address used by psql. Adjust accodring to your environment
STANDBY_SSH_HOST="10.1.0.20"       # SSH target for OS commands. Adjust accodring to your environment
STANDBY_SSH_USER="fsepuser"        # SSH user on current standby. Adjust accodring to your environment
STANDBY_PGDATA="/database/inst1"   # PGDATA on current standby. Adjust accodring to your environment
STANDBY_PORT=27500                 # Fujitsu Enterprise Postgres port on current standby. Adjust accodring to your environment

# Database users and connection behavior
REPL_USER="repluser"               # Has REPLICATION + LOGIN (for RO checks/slot ops). Adjust accodring to your environment
REPL_DB="postgres"                 # Database to connect for control SQL
REPL_SSLMODE="${REPL_SSLMODE:-prefer}"  # sslmode for all DB connections (prefer | require | disable)

# Superuser (or equivalent) for admin-only SQL like CHECKPOINT (can be same as REPL_USER if superuser)
PGUSER="fsepuser" # Adjust accodring to your environment

# application_name the rejoined follower will advertise
APP_NAME="standby" # Adjust accodring to your environment

# Replication slot handling (empty to disable). If set, we ensure this slot on NEW PRIMARY.
PRIMARY_SLOT_NAME="repl_slot1" # Adjust accodring to your environment

# Paths to Fujitsu Enterprise Postgres utilities on the remote hosts (override if not in PATH remotely)
PG_CTL="/opt/fsepv15server64/bin/pg_ctl" # Adjust accodring to your environment
PG_REWIND="/opt/fsepv15server64/bin/pg_rewind" # Adjust accodring to your environment
PSQL="psql"                        # psql on the controller host

# SSH binary and policy
SSH_BIN="${SSH_BIN:-/usr/bin/ssh}" 

# Promotion / lag waiting / verification
LAG_WAIT_BYTES=0                   # Require replay lag <= this many bytes before promoting (0 = fully caught up)
LAG_WAIT_TIMEOUT=120               # Max seconds to wait for catch-up (avoid infinite waits)
CHECKPOINT_AFTER_PROMOTION=true    # Ask NEW PRIMARY to CHECKPOINT after switch (needs superuser or pg_checkpoint role)

# Startup/verification timing knobs
START_WAIT_SECONDS=30     # protective cap for pg_ctl -w (if used)
REPL_WAIT_SECONDS=60       # poll window to see connections in pg_stat_replication
REPL_VERIFY=false                                # set true to poll pg_stat_replication after start

# If Postgres is managed by systemd, set unit names; else, we use pg_ctl
PRIMARY_SYSTEMD_UNIT=""            # e.g., "fep@17-main"
STANDBY_SYSTEMD_UNIT=""            # e.g., "fep@17-main"

# SSH authentication mode (keys recommended). If 1, allow interactive password prompt.
ALLOW_SSH_PASSWORD=0

# Mirroring Controller (MC) tool and post-switch behavior
MC_CTL="/opt/fsepv15server64/bin/mc_ctl" # Adjust accodring to your environment
MC_REFRESH_AFTER_SWITCH="true"   # if "true", stop/start MC with --mc-only on both nodes
MC_DIR= "/mc" # Mirroring Controller directory. Adjust accodring to your environment.

# synchronous_standby_names policy to apply on NEW PRIMARY after switchover
# e.g., "1 (standby)" means NEW PRIMARY will wait for ACK from application_name 'standby'
SYNC_STANDBY_NAMES_VALUE="standby" # Adjust accodring to your environment

# ====================================================================
# INTERNALS — Normally you don't need to change anything below
# ====================================================================
DRY_RUN=false

# ------------- Small utilities
LOG_TS() { date +"%Y-%m-%dT%H:%M:%S%z"; }
log()    { echo "[$(LOG_TS)] $*"; }
fail()   { log "ERROR: $*"; exit 1; }
need()   { command -v "$1" >/dev/null 2>&1 || fail "Missing binary: $1"; }
trim()   { printf "%s" "$1" | tr -d '[:space:]'; }

# is_local_host <host>
# Returns 0 if the given hostname/IP refers to this machine (helps avoid SSHing into self).
is_local_host() {
  local target="$1"
  [[ "$target" == "localhost" || "$target" == "127.0.0.1" || "$target" == "::1" ]] && return 0
  local hn fqdn
  hn=$(hostname -s 2>/dev/null || true)
  fqdn=$(hostname -f 2>/dev/null || true)
  [[ -n "$hn"   && "$target" == "$hn"   ]] && return 0
  [[ -n "$fqdn" && "$target" == "$fqdn" ]] && return 0
  local ip
  for ip in $(hostname -I 2>/dev/null); do
    [[ "$target" == "$ip" ]] && return 0
  done
  return 1
}

# run_clean <cmd...>
# Runs a command with a minimal/clean environment so we don't accidentally pick
# up weird libraries from the caller's shell (e.g., LD_LIBRARY_PATH).
run_clean() {
  env -i \
    PATH=/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C \
    HOME="$HOME" \
    SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-}" \
    "$@"
}

# run_ssh <host> <user> <command string>
# Executes a shell snippet on <host> as <user>.
# - If host is local, runs it directly (no SSH).
# - Accepts new host keys automatically; stores them in ~/.ssh/known_hosts.
# - Respects ALLOW_SSH_PASSWORD (BatchMode=yes/no).
run_ssh() {
  local host=$1 user=$2; shift 2

  if is_local_host "$host"; then
    # Local: avoid SSH; helpful when you run the controller on one of the nodes.
    if $DRY_RUN; then
      log "DRY-RUN (local) $*"
    else
      run_clean bash -lc "$*"
    fi
    return 0
  fi

  local kh="${HOME}/.ssh/known_hosts"
  if $DRY_RUN; then
    log "DRY-RUN ${SSH_BIN} ${user}@${host} -- $*"
  else
    local batchopt="-o BatchMode=yes"
    [[ "${ALLOW_SSH_PASSWORD:-0}" == "1" ]] && batchopt=""
    run_clean "$SSH_BIN" \
      $batchopt \
      -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile="$kh" \
      "${user}@${host}" "$@"
  fi
}

# psql_direct <host> <port> <sql>
# Executes a single SQL statement using REPL_USER for read-only control queries.
# - Uses PGPASSFILE or ~/.pgpass for auth.
# - -At (unaligned, tuples-only) makes parsing easy in shell.
psql_direct() {
  local host=$1 port=$2 sql=$3
  local passfile="${PGPASSFILE:-$HOME/.pgpass}"
  if $DRY_RUN; then
    >&2 echo "[$(LOG_TS)] DRY-RUN (exec RO) PGPASSFILE='$passfile' PGCONNECT_TIMEOUT=5 $PSQL -w -h $host -p $port -U $PGUSER -d $REPL_DB -Atc \"$sql\""
  fi
  PGPASSFILE="$passfile" PGCONNECT_TIMEOUT=5 \
    $PSQL -w -h "$host" -p "$port" -U "$REPL_USER" -d "$REPL_DB" -v ON_ERROR_STOP=1 -Atc "$sql"
}

# psql_admin <host> <port> <sql>
# Executes admin-level SQL using PGUSER (e.g., CHECKPOINT). Requires suitable privileges.
psql_admin() {
  local host=$1 port=$2 sql=$3
  local passfile="${PGPASSFILE:-$HOME/.pgpass}"
  PGPASSFILE="$passfile" PGCONNECT_TIMEOUT=5 \
    $PSQL -w -h "$host" -p "$port" -U "$PGUSER" -d "$REPL_DB" -v ON_ERROR_STOP=1 -Atc "$sql"
}

# -------------------------
# SSH known_hosts preparation (fingerprints + quick reachability)
# -------------------------
prepare_ssh_hosts() {
  log "Preparing ~/.ssh known_hosts for ${PRIMARY_HOST} and ${STANDBY_HOST}"

  mkdir -p ~/.ssh
  chmod 700 ~/.ssh

  # Clean stale keys (skip if the host is actually 'self')
  ! is_local_host "$PRIMARY_HOST" && ssh-keygen -R "$PRIMARY_HOST" 2>/dev/null || true
  ! is_local_host "$STANDBY_HOST" && ssh-keygen -R "$STANDBY_HOST" 2>/dev/null || true

  # Preload current host keys (avoids interactivity during first SSH)
  ! is_local_host "$PRIMARY_HOST" && ssh-keyscan -T 5 "$PRIMARY_HOST" >> ~/.ssh/known_hosts 2>/dev/null || true
  ! is_local_host "$STANDBY_HOST" && ssh-keyscan -T 5 "$STANDBY_HOST" >> ~/.ssh/known_hosts 2>/dev/null || true
  chmod 600 ~/.ssh/known_hosts || true

  # Smoke test SSH if remote (quietly). This does not fail the script—just warns.
  local ok=true
  if ! is_local_host "$PRIMARY_HOST"; then
    /usr/bin/env -u LD_LIBRARY_PATH ssh -o BatchMode=yes "$PRIMARY_SSH_USER@$PRIMARY_HOST" 'echo ok' >/dev/null 2>&1 || ok=false
  fi
  if ! is_local_host "$STANDBY_HOST"; then
    /usr/bin/env -u LD_LIBRARY_PATH ssh -o BatchMode=yes "$STANDBY_SSH_USER@$STANDBY_HOST" 'echo ok' >/dev/null 2>&1 || ok=false
  fi
  $ok && log "SSH host verification succeeded." || log "WARNING: SSH host check failed; verify connectivity or fingerprints."
}

usage() {
  cat <<EOF
Usage:
  $0 --dry-run    # Read-only checks (connectivity, roles, lag). No changes are made.
  $0 --execute    # Perform the switchover (promote, fence, rewind, rejoin, MC refresh).
EOF
}

# -------------------------
# Preflight: tools, connectivity, and role sanity checks
# -------------------------
preflight() {
  log "Preflight: validating required tools on control host"
  need "$PSQL"
  need "$SSH_BIN"
  need "$PG_CTL"
  need "$PG_REWIND"

  log "Preflight: testing command path (SSH or local if self)"
  if $DRY_RUN; then
    log "DRY-RUN command check primary ${PRIMARY_SSH_USER}@${PRIMARY_SSH_HOST}"
    log "DRY-RUN command check standby  ${STANDBY_SSH_USER}@${STANDBY_SSH_HOST}"
  else
    run_ssh "$PRIMARY_SSH_HOST" "$PRIMARY_SSH_USER" 'echo primary_ok' \
      || fail "Command path failed for PRIMARY host $PRIMARY_SSH_HOST"
    run_ssh "$STANDBY_SSH_HOST" "$STANDBY_SSH_USER" 'echo standby_ok' \
      || fail "Command path failed for STANDBY host $STANDBY_SSH_HOST"
  fi

  log "Preflight: verifying Fujitsu Enterprise Postgres is reachable on both nodes as $REPL_USER (direct TCP)"
  psql_direct "$PRIMARY_HOST" "$PRIMARY_PORT" 'SELECT version();' >/dev/null || fail "psql to primary failed"
  psql_direct "$STANDBY_HOST" "$STANDBY_PORT"  'SELECT version();' >/dev/null || fail "psql to standby failed"

  log "Preflight: verifying roles (primary vs standby)"
  local prim_in_recov std_in_recov
  prim_in_recov=$(trim "$(psql_direct "$PRIMARY_HOST" "$PRIMARY_PORT" 'SELECT pg_is_in_recovery();' 2>/dev/null || true)")
  std_in_recov=$(trim  "$(psql_direct "$STANDBY_HOST"  "$STANDBY_PORT"  'SELECT pg_is_in_recovery();'  2>/dev/null || true)")
  log "Primary recovery status: ${prim_in_recov:-<empty>} (expected f)"
  log "Standby  recovery status: ${std_in_recov:-<empty>} (expected t)"
  [[ "$prim_in_recov" == "f" ]] || fail "Expected PRIMARY ($PRIMARY_HOST) to NOT be in recovery"
  [[ "$std_in_recov"  == "t" ]] || fail "Expected STANDBY ($STANDBY_HOST) to be in recovery"
}

# -------------------------
# Step 1: Wait for catch-up before promotion
# -------------------------
wait_for_catchup() {
  log "Checking replication lag before promotion (direct TCP)"
  local primary_lsn standby_replay_lsn lag_bytes deadline

  # Take an initial measurement (helps operators see where we started)
  primary_lsn=$(psql_direct "$PRIMARY_HOST" "$PRIMARY_PORT" 'SELECT pg_current_wal_lsn();')
  standby_replay_lsn=$(psql_direct "$STANDBY_HOST" "$STANDBY_PORT" 'SELECT pg_last_wal_replay_lsn();')
  lag_bytes=$(psql_direct "$STANDBY_HOST" "$STANDBY_PORT" "SELECT COALESCE(pg_wal_lsn_diff('$primary_lsn', pg_last_wal_replay_lsn())::bigint,0);")
  log "Initial LSNs: primary=$primary_lsn standby_replay=$standby_replay_lsn lag=${lag_bytes} bytes"

  # If LAG_WAIT_BYTES >= 0, we wait until the replay delay is within the threshold (or we time out).
  if (( LAG_WAIT_BYTES >= 0 )); then
    log "Waiting until lag <= ${LAG_WAIT_BYTES} bytes (timeout ${LAG_WAIT_TIMEOUT}s)"
    deadline=$(( $(date +%s) + LAG_WAIT_TIMEOUT ))
    while (( $(date +%s) <= deadline )); do
      primary_lsn=$(psql_direct "$PRIMARY_HOST" "$PRIMARY_PORT" 'SELECT pg_current_wal_lsn();')
      standby_replay_lsn=$(psql_direct "$STANDBY_HOST" "$STANDBY_PORT" 'SELECT pg_last_wal_replay_lsn();')
      lag_bytes=$(psql_direct "$STANDBY_HOST" "$STANDBY_PORT" "SELECT COALESCE(pg_wal_lsn_diff('$primary_lsn', pg_last_wal_replay_lsn())::bigint,0);")
      log "lag=${lag_bytes} bytes (primary=$primary_lsn standby_replay=$standby_replay_lsn)"
      (( lag_bytes <= LAG_WAIT_BYTES )) && break
      sleep 2
    done
    (( lag_bytes <= LAG_WAIT_BYTES )) || fail "Standby did not catch up within timeout; aborting"
  fi
}

# -------------------------
# Step 2: Promote the standby to NEW PRIMARY
# -------------------------
promote_standby() {
  log "Promoting standby on ${STANDBY_SSH_HOST} (pg_ctl promote)"
  if [[ -n "$STANDBY_SYSTEMD_UNIT" ]]; then
    # If systemd manages postgres, make sure we reload/restart as needed, then promote explicitly.
    run_ssh "$STANDBY_SSH_HOST" "$STANDBY_SSH_USER" "sudo -n systemctl reload-or-restart '$STANDBY_SYSTEMD_UNIT' || true; $PG_CTL -D '$STANDBY_PGDATA' promote"
  else
    run_ssh "$STANDBY_SSH_HOST" "$STANDBY_SSH_USER" "$PG_CTL -D '$STANDBY_PGDATA' promote"
  fi

  # Verify we left recovery (pg_is_in_recovery() -> f)
  local recov
  recov=$(trim "$(psql_direct "$STANDBY_HOST" "$STANDBY_PORT" 'SELECT pg_is_in_recovery();')")
  [[ "$recov" == "f" ]] || fail "Standby did not leave recovery after promotion"
}

# -------------------------
# Step 3: Stop the old primary fast (fencing to avoid divergence)
# -------------------------
stop_old_primary() {
  log "Stopping old primary (fast) on ${PRIMARY_SSH_HOST}"
  if [[ -n "$PRIMARY_SYSTEMD_UNIT" ]]; then
    run_ssh "$PRIMARY_SSH_HOST" "$PRIMARY_SSH_USER" "sudo -n systemctl stop '$PRIMARY_SYSTEMD_UNIT'"
  else
    run_ssh "$PRIMARY_SSH_HOST" "$PRIMARY_SSH_USER" "$PG_CTL -D '$PRIMARY_PGDATA' -m fast stop"
  fi
}

# -------------------------
# Step 4: Ensure a physical slot on NEW PRIMARY (optional)
# -------------------------
ensure_slot_on_new_primary() {
  if [[ -z "$PRIMARY_SLOT_NAME" ]]; then
    log "Slotless mode: skipping slot creation."
    return
  fi
  log "Ensuring physical slot '$PRIMARY_SLOT_NAME' exists on new primary"
  local has
  has=$(trim "$(psql_direct "$STANDBY_HOST" "$STANDBY_PORT" "SELECT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name='$PRIMARY_SLOT_NAME');")")
  if [[ "$has" == "f" ]]; then
    psql_direct "$STANDBY_HOST" "$STANDBY_PORT" "SELECT pg_create_physical_replication_slot('$PRIMARY_SLOT_NAME');"
    log "Created slot '$PRIMARY_SLOT_NAME' on new primary"
  else
    log "Slot '$PRIMARY_SLOT_NAME' already exists"
  fi
}

# -------------------------
# Step 5: Rewind the old primary to the NEW PRIMARY timeline
# -------------------------
rewind_old_primary() {
  log "Running pg_rewind on old primary against new primary (jit=off, clean env)"
  local source_conn
  # We use PGUSER for the source connection. This user must be able to connect to NEW PRIMARY.
  source_conn="host=${STANDBY_HOST} port=${STANDBY_PORT} user=${PGUSER} dbname=${REPL_DB} sslmode=${REPL_SSLMODE}"

  # Clear LD_LIBRARY_PATH and force JIT off, to avoid environmental surprises during rewind.
  local cmd="env -u LD_LIBRARY_PATH PGOPTIONS='-c jit=off' \
    ${PG_REWIND} --target-pgdata='${PRIMARY_PGDATA}' \
                  --source-server=\"${source_conn}\" \
                  --progress"

  run_ssh "${PRIMARY_SSH_HOST}" "${PRIMARY_SSH_USER}" "${cmd}"
}

# -------------------------
# Step 6: Configure the old primary to follow the NEW PRIMARY
# -------------------------
configure_old_primary_as_standby() {
  log "Configuring old primary as standby"
  local conninfo
  # We write primary_conninfo/+primary_slot_name into postgresql.auto.conf so it's easy to overwrite later.
  conninfo="primary_conninfo = 'host=${STANDBY_HOST} port=${STANDBY_PORT} user=${REPL_USER} dbname=${REPL_DB} application_name=${APP_NAME} sslmode=${REPL_SSLMODE}'"

  # The remote script:
  # - remove any old recovery.conf/signal
  # - ensure standby.signal exists (enter recovery on next start)
  # - rewrite postgresql.auto.conf without any previous primary_conninfo/primary_slot_name lines
  # - append new primary_conninfo (+ primary_slot_name if enabled)
  local cmd="set -e; cd '$PRIMARY_PGDATA';
    rm -f recovery.conf recovery.signal;
    touch standby.signal;
    if [ -f postgresql.auto.conf ]; then
      awk '!/^primary_conninfo|^primary_slot_name/' postgresql.auto.conf > postgresql.auto.conf.tmp || true;
      mv -f postgresql.auto.conf.tmp postgresql.auto.conf || true;
    fi
    echo \"$conninfo\" >> postgresql.auto.conf;"

  if [[ -n "$PRIMARY_SLOT_NAME" ]]; then
    cmd="$cmd
    echo \"primary_slot_name = '${PRIMARY_SLOT_NAME}'\" >> postgresql.auto.conf;"
  else
    log "Slotless mode: not writing primary_slot_name."
  fi

  run_ssh "$PRIMARY_SSH_HOST" "$PRIMARY_SSH_USER" "$cmd"
}

# -------------------------
# Step 7: Start the rejoined node and (optionally) verify replication on NEW PRIMARY
# -------------------------
start_and_verify_follow() {
  log "Starting old primary (now standby)"
  if [[ -n "$PRIMARY_SYSTEMD_UNIT" ]]; then
    # systemd start returns quickly; we still guard with timeout.
    run_ssh "$PRIMARY_SSH_HOST" "$PRIMARY_SSH_USER" \
      "timeout 20s sudo -n systemctl start '$PRIMARY_SYSTEMD_UNIT' >/dev/null 2>&1 || true"
  else
    # Use pg_ctl in a detached way so SSH doesn't wait on server logs.
    run_ssh "$PRIMARY_SSH_HOST" "$PRIMARY_SSH_USER" \
      "setsid nohup $PG_CTL -D '$PRIMARY_PGDATA' -W start >/dev/null 2>&1 < /dev/null & disown || true"
  fi

  log "Start command returned (past 'server started')."

  # Optional visibility check: look for any rows in pg_stat_replication on NEW PRIMARY
  if [[ "${REPL_VERIFY}" != "true" ]]; then
    log "Replication verification disabled (REPL_VERIFY=false). Skipping pg_stat_replication poll."
    return 0
  fi

  log "Verifying replication from new primary (direct TCP) for up to ${REPL_WAIT_SECONDS}s"
  local rows="" i=0 tries=$(( REPL_WAIT_SECONDS / 2 )); (( tries < 1 )) && tries=1
  while (( i < tries )); do
    i=$(( i + 1 ))
    rows=$(psql_direct "$STANDBY_HOST" "$STANDBY_PORT" \
      "SELECT client_addr||':'||application_name||':'||state||':'||sync_state
         FROM pg_stat_replication ORDER BY 1 LIMIT 5;" 2>/dev/null || true)
    if [[ -n "$rows" ]]; then
      log "pg_stat_replication on new primary: $rows"
      return 0
    fi
    log "pg_stat_replication: (no rows yet) — attempt ${i}/${tries}; waiting 2s..."
    sleep 2
  done
  log "WARNING: no replication connections visible after ${REPL_WAIT_SECONDS}s. Continuing — check primary_conninfo/pg_hba/logs."
}

# -------------------------
# Set synchronous_standby_names on the NEW PRIMARY and reload
# -------------------------
set_sync_standby_on_new_primary() {
  log "Setting synchronous_standby_names='${SYNC_STANDBY_NAMES_VALUE}' in ${STANDBY_PGDATA}/postgresql.conf (NEW PRIMARY)"

  # We surgically remove any existing synchronous_standby_names line and append our target setting.
  local edit_cmd="
    set -e
    CONF='${STANDBY_PGDATA}/postgresql.conf'
    TMP=\$(mktemp)
    awk '!/^[[:space:]]*#?[[:space:]]*synchronous_standby_names[[:space:]]*=/' \"\$CONF\" > \"\$TMP\"
    printf \"\\nsynchronous_standby_names = '%s'\\n\" \"${SYNC_STANDBY_NAMES_VALUE}\" >> \"\$TMP\"
    mv -f \"\$TMP\" \"\$CONF\"
  "
  run_ssh "${STANDBY_SSH_HOST}" "${STANDBY_SSH_USER}" "${edit_cmd}"

  # Reload to apply the change
  if [[ -n "$STANDBY_SYSTEMD_UNIT" ]]; then
    run_ssh "$STANDBY_SSH_HOST" "$STANDBY_SSH_USER" "sudo -n systemctl reload '$STANDBY_SYSTEMD_UNIT'"
  else
    run_ssh "$STANDBY_SSH_HOST" "$STANDBY_SSH_USER" "$PG_CTL -D '$STANDBY_PGDATA' reload"
  fi

  # Double-check effective value via SHOW (whitespace-insensitive compare)
  local eff eff_norm exp_norm
  eff=$(trim "$(psql_direct "${STANDBY_HOST}" "${STANDBY_PORT}" "SHOW synchronous_standby_names;")")
  eff_norm="$(printf '%s' "$eff" | tr -d '[:space:]')"
  exp_norm="$(printf '%s' "${SYNC_STANDBY_NAMES_VALUE}" | tr -d '[:space:]')"
  log "Effective synchronous_standby_names on NEW PRIMARY: ${eff}"
  [[ "$eff_norm" == "$exp_norm" ]] || fail "synchronous_standby_names did not apply as expected (got '$eff', wanted '${SYNC_STANDBY_NAMES_VALUE}')"
}

# -------------------------
# Refresh Mirroring Controller (MC) on both nodes with --mc-only
# -------------------------
mc_refresh_after_switch() {
  $MC_REFRESH_AFTER_SWITCH || { log "MC refresh disabled; skipping."; return; }
  log "Refreshing Mirroring Controller on BOTH nodes (--mc-only)"

  # Ensure MC spawns postgres with known PATH; also strip LD_LIBRARY_PATH to avoid surprises.
  local ENV_WRAP="env -u LD_LIBRARY_PATH PATH=/opt/fsepv15server64/bin:/usr/sbin:/usr/bin" # Adjust according to your FEP environment

  # Bounded stops (ignore failures if MC is already stopped)
  run_ssh "$PRIMARY_SSH_HOST" "$PRIMARY_SSH_USER" "$ENV_WRAP timeout 20s '$MC_CTL' stop  -M $MC_DIR --mc-only >/dev/null 2>&1 || true"
  run_ssh "$STANDBY_SSH_HOST"  "$STANDBY_SSH_USER"  "$ENV_WRAP timeout 20s '$MC_CTL' stop -M $MC_DIR --mc-only >/dev/null 2>&1 || true"

  # Bounded starts
  run_ssh "$PRIMARY_SSH_HOST" "$PRIMARY_SSH_USER"   "$ENV_WRAP timeout 30s '$MC_CTL' start -M $MC_DIR --mc-only >/dev/null 2>&1 || true"
  run_ssh "$STANDBY_SSH_HOST"  "$STANDBY_SSH_USER"  "$ENV_WRAP timeout 30s '$MC_CTL' start -M $MC_DIR --mc-only >/dev/null 2>&1 || true"

  log "MC refresh completed on both nodes."
}

# -------------------------
# Step 8: Post tasks (optional CHECKPOINT, sync names, MC refresh)
# -------------------------
post_tasks() {
  if $CHECKPOINT_AFTER_PROMOTION; then
    log "Running CHECKPOINT on new primary"
    if ! psql_admin "$STANDBY_HOST" "$STANDBY_PORT" "CHECKPOINT;" 2>/dev/null; then
      log "WARNING: CHECKPOINT skipped — '$PGUSER' needs SUPERUSER or pg_checkpoint."
    fi
  fi

  # Enforce explicit synchronous_standby_names on NEW PRIMARY (keeps policy consistent after switch)
  set_sync_standby_on_new_primary

  # Restart MC control-plane only (not the database) so it re-reads states after the switch
  mc_refresh_after_switch

  log "Switchover complete. Update application routing/load balancer if needed."
}

# -------------------------
# Main entry point
# -------------------------
main() {
  local mode=${1:-"--dry-run"}

  # Make SSH non-interactive and safe before any remote command runs
  prepare_ssh_hosts

  case "$mode" in
    --dry-run) DRY_RUN=true ;;     # Only read/verify. No state changes.
    --execute) ;;                  # Perform the full switchover.
    --help|-h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac

  # Sanity checks before we touch anything
  preflight
  wait_for_catchup

  if $DRY_RUN; then
    log "Dry-run complete. No state changes made. Rerun with --execute to proceed."
    exit 0
  fi

  # Switchover sequence (order matters)
  promote_standby                # Step 2
  stop_old_primary               # Step 3 (fence old primary immediately after promotion)
  ensure_slot_on_new_primary     # Step 4 (optional, harmless if slot already exists)
  rewind_old_primary             # Step 5 (align timelines to avoid base backup)
  configure_old_primary_as_standby  # Step 6 (write primary_conninfo/+slot, create standby.signal)
  start_and_verify_follow        # Step 7 (start follower; optional pg_stat_replication check)
  post_tasks                     # Step 8/9 (checkpoint, sync names, MC refresh)

  log "SUCCESS: Switchover finished."
}

main "$@"
