#!/usr/bin/env bash
# =================================================================================================== #
#  fep_rebuild_sr.sh — Rebuild FEP Sync Streaming Replication with MC orchestration                   #
#  Author: Kothari Nishchay
#
#  PURPOSE:
#    This script rebuilds a broken replica in a two-node Fujitsu Enterprise Postgres (FEP) cluster
#    that is managed by the Mirroring Controller (MC). It covers two common situations:
#      1) The standby died or got corrupted -> rebuild it from the active primary.
#      2) We failed over to the standby (old primary is now behind) -> rewind or restore the old
#         primary and rejoin it as the new standby.
#
#  WHY USE mc_ctl:
#    In FEP, MC is the source of truth for service state. Starting/stopping Postgres with mc_ctl
#    keeps MC's state aligned with the database state. Using pg_ctl directly can confuse MC and
#    break automated failover/switchover logic.
#
#  Supported scenarios:
#    - rebuild-standby       : run on the node that SHOULD be the standby (10.1.0.21 in the example)
#    - rebuild-old-primary   : run on the old primary after failover, to rejoin as standby
#
#  Usage examples:
#    On STANDBY node (10.1.0.21) after a standby failure:
#      ./fep_rebuild_sr.sh rebuild-standby
#
#    On OLD PRIMARY node (10.1.0.20) after failover (standby became primary):
#      ./fep_rebuild_sr.sh rebuild-old-primary
#
#  Exit codes:
#    0 = success
#   >0 = failure (check the log file shown at start)
#
#  Pre-reqs:
#    - Passwordless or .pgpass-based psql authentication to both nodes for the superuser (PGUSER).
#    - Replication user (RPLUSER) exists and has REPLICATION privilege.
#    - pgBackRest configured if you want the fast restore path (stanza reachable).
#    - wal_log_hints=on OR data checksums enabled if you want pg_rewind to work.
# ---------------------------------------------------------------------------------------------------
#  pgBackRest Authentication Notes
# ---------------------------------------------------------------------------------------------------
# pgBackRest connects over SSH when the repository is on a remote host (repo1-host).
#
# In this environment:
#     - Repository Host : 10.1.0.19
#     - Primary         : 10.1.0.21
#     - Standby         : 10.1.0.20
#
# REQUIREMENT:
#   Each database node (10.1.0.20 and 10.1.0.21) must be able to SSH into the repository host
#      (10.1.0.19) **without password**, as the configured repo user (e.g., "pgbackrest").
#
#      Example setup (on both DB nodes):
#         [fsepuser@10.1.0.20]$ sudo -iu pgbackrest
#         $ ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
#         $ ssh-copy-id pgbackrest@10.1.0.19
#
#      Verify:
#         $ ssh pgbackrest@10.1.0.19 "hostname"
#
#   The repo host (10.1.0.19) must accept SSH from both DB nodes for pgBackRest operations.
#
#   pgBackRest configuration on each DB node must specify:
#         repo1-host=10.1.0.19
#         repo1-host-user=pgbackrest
#
#   No SSH is required between the Primary (10.1.0.21) and Standby (10.1.0.20) for this script.
#   The script communicates between them using PostgreSQL TCP (via psql, pg_basebackup, pg_rewind).
#
#   Database-to-database access should instead use .pgpass for passwordless DB authentication:
#         ~/.pgpass entries for both 10.1.0.20 and 10.1.0.21
#
# Summary:
#   - DB → Repo host  : SSH key-based (for pgBackRest restore/backup)
#   - DB ↔ DB         : .pgpass (for SQL, pg_basebackup, pg_rewind)
# =================================================================================================== #

set -euo pipefail
set -o errtrace

# ---- Centralized error reporter: shows failing line and command so triage is faster.
err_report() {
  local rc=$?
  log "ERROR: Command failed (rc=${rc}) at line ${BASH_LINENO[0]}: ${BASH_COMMAND}"
  log "See log file: $LOG_FILE"
}
trap err_report ERR

IFS=$'\n\t'

# -------------------------
# CONFIGURATION (edit me)
# -------------------------
# NOTE: These addresses represent the intended roles in a healthy state, not necessarily current.
PRIMARY_IP="10.1.0.21" # Adjust accodring to your environment
STANDBY_IP="10.1.0.20" # Adjust accodring to your environment

# Postgres paths (FEP install)
export PGDATA="/database/inst1" # FEP Data directory path. Adjust accodring to your environment
export PGBIN="/opt/fsepv15server64/bin"
export PATH="$PGBIN:$PATH" 

# MC management directory for THIS instance on THIS server
MCDIR="/mc"   # Make sure this matches your MC deployment directory on the node. Adjust accodring to your environment

# pgBackRest settings (optional but recommended for speed and consistency)
PGBR_BIN="/opt/fsepv15client64/OSS/pgbackrest/bin/pgbackrest"  # set absolute path if not in $PATH environment variable
PGBR_STANZA="fep15"  # Adjust accodring to your environment

# PostgreSQL connectivity for checks/admin operations
PGPORT="27500" # Adjust accodring to your environment
PGUSER="fsepuser"   # Superuser able to run health checks and pg_rewind source connects. Adjust accodring to your environment
RPLUSER="repluser" # replication user referenced in primary_conninfo. Adjust accodring to your environment

# Fixed slot name (optional). If empty, we try to reuse/auto-detect; else script will create/ensure this one.
SLOT_NAME="repl_slot1" # Adjust accodring to your environment

# Logging — we always tee important messages so the operator can see progress in real-time.
LOG_DIR="/home/fsepuser/scripts/log"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/fep_rebuild_sr_$(date +%Y%m%d_%H%M%S).log"

# -------------------------
# UTILITY FUNCTIONS
# -------------------------
# Consistent logging helpers and command guards.
log(){ echo "[$(date +'%F %T')] $*" | tee -a "$LOG_FILE" >&2; }
die(){ log "ERROR: $*"; exit 1; }
need_cmd(){ command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

# Run SQL on a target host quickly and quietly (no headers/footers).
psql_exec(){ # usage: psql_exec <host> <sql...>
  local host="$1"; shift
  psql "host=${host} port=${PGPORT} user=${PGUSER} dbname=postgres" -Atc "$*" 2>>"$LOG_FILE"
}

# Lightweight local-role checks using IP addresses (not authoritative, just a hint for operators).
is_local_primary(){ hostname -I 2>/dev/null | tr ' ' '\n' | grep -qx "$PRIMARY_IP"; }
is_local_standby(){ hostname -I 2>/dev/null | tr ' ' '\n' | grep -qx "$STANDBY_IP"; }

# -------------------------
# ACTIVE PRIMARY DETECTION
# -------------------------
# Script don't trust our static PRIMARY_IP blindly. Script probe both nodes and ask "who is not in recovery?"
ACTIVE_PRIMARY="$PRIMARY_IP"
detect_active_primary() {
  log "Detecting active primary by probing ${PRIMARY_IP} and ${STANDBY_IP}..."
  for host in "$PRIMARY_IP" "$STANDBY_IP"; do
    # We run the check twice deliberately:
    #  - first to ensure connection is possible,
    #  - second to assert the boolean result is TRUE ('t').
    if [[ -n "$(psql_exec "$host" "select not pg_is_in_recovery()")" ]] && \
       psql_exec "$host" "select not pg_is_in_recovery()" | grep -qx t; then
      ACTIVE_PRIMARY="$host"
      log "Active primary detected at: ${ACTIVE_PRIMARY}"
      return 0
    fi
  done
  die "Could not detect an active primary on ${PRIMARY_IP} or ${STANDBY_IP}."
}

# -------------------------
# MC CONTROL HELPERS (robust)
# -------------------------
# These helpers make stopping/starting safe and visible. Script wait until Postgres and MC are truly down.

# Check if Postgres is still alive (PID file or domain socket). Prevents races on start/stop.
pg_is_up(){
  # Method 1: PID file + live process
  if [[ -f "$PGDATA/postmaster.pid" ]]; then
    local pid
    pid="$(head -1 "$PGDATA/postmaster.pid" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && ps -p "$pid" >/dev/null 2>&1; then
      return 0
    fi
  fi
  # Method 2: Unix socket still bound (db may be up or stuck in startup/shutdown)
  if ss -xl 2>/dev/null | grep -qE "\.s\.PGSQL\.${PGPORT}\b"; then
    return 0
  fi
  return 1
}

# If Postgres crashed and left a stale PID, remove it safely so a clean start is possible.
pg_clear_stale_pid(){
  if [[ -f "$PGDATA/postmaster.pid" ]]; then
    local pid
    pid="$(head -1 "$PGDATA/postmaster.pid" 2>/dev/null || true)"
    if [[ -z "$pid" || ! $(ps -p "$pid" -o pid= 2>/dev/null) ]]; then
      log "Found stale postmaster.pid; removing it."
      rm -f "$PGDATA/postmaster.pid" || true
    fi
  fi
}

# Detect MC processes that are managing THIS instance (by matching the -M <MCDIR> argument).
mc_procs_present(){
  pgrep -fa "mc_(main|watch|agent).* -M[[:space:]]*$MCDIR\b" >/dev/null 2>&1
}

# Consider "MC running" if either MC procs exist OR Postgres is still up.
# Rationale: some MC builds can be in transition; we want both to be down for a clean rebuild.
mc_is_running(){
  if mc_procs_present; then return 0; fi
  if pg_is_up; then return 0; fi
  return 1
}

# Start MC (and Postgres). Optional "disable-failover" mode allows staged bring-up without auto-switch.
mc_start(){
  local mode="${1:-enable-failover}"
  log "Starting Mirroring Controller (and instance) via mc_ctl... (mode=${mode})"
  if [[ "$mode" == "disable-failover" ]]; then
    mc_ctl start -M "$MCDIR" -F | tee -a "$LOG_FILE"
  else
    mc_ctl start -M "$MCDIR"       | tee -a "$LOG_FILE"
  fi
}

# Status is best-effort; never fail the whole script on status errors.
mc_status(){
  log "MC status (this node):"
  mc_ctl status -M "$MCDIR" | tee -a "$LOG_FILE" || true
}

# Stop MC (and Postgres) cleanly. Some versions return 0 when already stopped — that's fine.
mc_stop(){
  log "Stopping Mirroring Controller (and instance) via mc_ctl..."
  mc_ctl stop -M "$MCDIR" | tee -a "$LOG_FILE" || true
}

# Keep stopping until both MC and Postgres are really down, with a timeout and clear progress logs.
ensure_mc_stopped(){
  local TIMEOUT="${1:-90}" SLEEP=2 waited=0

  mc_stop

  while mc_is_running; do
    (( waited >= TIMEOUT )) && {
      log "MC/PG still appear up after ${TIMEOUT}s."
      # Last-ditch cleanup for typical crash leftovers:
      pg_clear_stale_pid
      if mc_is_running; then
        die "MC did not stop cleanly within ${TIMEOUT}s; aborting to avoid corruption."
      fi
      break
    }
    if mc_procs_present; then
      log "…MC processes still present; waiting."
    elif pg_is_up; then
      log "…Postgres still up (PID/socket); waiting."
    fi
    sleep "$SLEEP"; (( waited += SLEEP ))
  done

  log "Confirmed: MC and Postgres are stopped (no MC procs, no PID/socket)."
}

# -------------------------
# DATA RESET / RECOVERY CFG
# -------------------------
# Wipes PGDATA safely (protection against rm -rf /). Only used before a full restore.
wipe_pgdata(){
  [[ -n "$PGDATA" && "$PGDATA" != "/" ]] || die "PGDATA looks unsafe: '$PGDATA'"
  log "WIPING data directory: $PGDATA"
  rm -rf "${PGDATA:?}/"* "${PGDATA:?}/".* 2>/dev/null || true
}

# Create standby.signal if missing — ensures the instance starts in recovery as a physical standby.
ensure_standby_signal() {
  if [[ ! -f "$PGDATA/standby.signal" ]]; then
    log "Creating standby.signal"
    : > "$PGDATA/standby.signal"
  fi
}

# Helper to add/replace a GUC in postgresql.auto.conf (idempotent).
set_auto_conf(){
  local key="$1" val="$2"
  sed -i "/^[[:space:]]*${key}[[:space:]]*=/d" "$PGDATA/postgresql.auto.conf" 2>/dev/null || true
  echo "${key} = ${val}" >> "$PGDATA/postgresql.auto.conf"
}

# Add primary_conninfo with the right user and app name (we don't trust default -R output fully).
ensure_primary_conninfo(){
  local appname="standby"
  local conn=" 'host=${ACTIVE_PRIMARY} port=${PGPORT} user=${RPLUSER} application_name=${appname}' "
  log "Setting primary_conninfo (application_name='${appname}')"
  set_auto_conf "primary_conninfo" "$conn"
}

# Pin the primary_slot_name for safer retention of WAL on primary (if you use slots).
ensure_primary_slot_name(){
  local slot="$1"
  [[ -n "$slot" ]] || die "ensure_primary_slot_name(): empty slot name"
  log "Setting primary_slot_name='${slot}'"
  set_auto_conf "primary_slot_name" "'${slot}'"
}

# Make sure the standby can fetch historical WAL from your pgBackRest repo during catch-up.
ensure_restore_command(){
  # Using archive-get is robust when network glitches drop streaming; the standby will pull missing WAL.
  local cmd="'${PGBR_BIN} --stanza=${PGBR_STANZA} archive-get %f %p'"
  log "Setting restore_command=${cmd}"
  set_auto_conf "restore_command" "$cmd"
}

# Reuse a slot name if already present locally; otherwise try to discover an existing one on primary.
extract_local_primary_slot_name() {
  local f="$PGDATA/postgresql.auto.conf"
  [[ -r "$f" ]] || return 1
  awk -F"=" '/^[[:space:]]*primary_slot_name[[:space:]]*=/{gsub(/'\''|"/,"",$2); gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2}' "$f" 2>/dev/null
}

# Pick any physical slot from the primary if available (prefers active ones).
detect_physical_slot_on_primary() {
  psql_exec "$ACTIVE_PRIMARY" \
    "select slot_name from pg_replication_slots where slot_type='physical' order by active desc, slot_name limit 1"
}

# Ensure the chosen slot exists on the primary. If PGUSER isn't superuser, we log and continue safely.
ensure_physical_slot_on_primary(){
  local slot="$1"
  [[ -n "$slot" ]] || die "ensure_physical_slot_on_primary(): empty slot name"

  log "Ensuring physical replication slot '${slot}' exists on ${ACTIVE_PRIMARY}"

  set +e
  local is_super
  is_super="$(psql_exec "$ACTIVE_PRIMARY" "select rolsuper from pg_roles where rolname = current_user;" 2>>"$LOG_FILE")"
  local rc=$?
  set -e

  if [[ $rc -ne 0 || "$is_super" != "t" ]]; then
    log "NOTE: PGUSER='${PGUSER}' is not superuser on ${ACTIVE_PRIMARY} (or check failed)."
    log "      Skipping slot creation; expecting slot '${slot}' to already exist OR standby to run without a slot."
    return 0
  fi

  # Create slot if missing; never hard-fail here (cluster may still be fine without a slot).
  set +e
  psql_exec "$ACTIVE_PRIMARY" "
    do \$\$
    begin
      if not exists (
        select 1 from pg_replication_slots
        where slot_name='${slot}' and slot_type='physical'
      ) then
        perform pg_create_physical_replication_slot('${slot}', true);
      end if;
    end
    \$\$;
  " 2>>"$LOG_FILE"
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    log "WARNING: Failed to create replication slot '${slot}' on ${ACTIVE_PRIMARY} (continuing)."
    log "         Ensure the slot exists if you rely on 'primary_slot_name=${slot}'."
  fi
}

# Decide which slot name to use: fixed, local-configured, discovered on primary, or a hostname-based default.
resolve_slot_name() {
  local chosen=""
  if [[ -n "${SLOT_NAME:-}" ]]; then
    chosen="$SLOT_NAME"
  else
    local local_slot="$(extract_local_primary_slot_name || true)"
    if [[ -n "$local_slot" ]]; then
      chosen="$local_slot"
    else
      local det="$(detect_physical_slot_on_primary || true)"
      if [[ -n "$det" ]]; then chosen="$det"; else chosen="$(hostname -s)-slot"; fi
    fi
  fi
  echo "$chosen"
}

# -------------------------
# RESTORE PATHS
# -------------------------
# pgBackRest path — fast and consistent. We set recovery options during restore for a ready-to-follow standby.
restore_via_pgbackrest(){
  need_cmd "$PGBR_BIN"
  local appname="$1" slot="$2"

  log "Restoring with pgBackRest (stanza='${PGBR_STANZA}') into $PGDATA ..."
  "$PGBR_BIN" restore \
    --stanza="${PGBR_STANZA}" \
    --db-path="${PGDATA}" \
    --type=standby \
    --delta \
    --force \
    --log-level-console=detail \
    --recovery-option="restore_command=${PGBR_BIN} --stanza=${PGBR_STANZA} archive-get %f %p" \
    --recovery-option="primary_conninfo=host=${ACTIVE_PRIMARY} port=${PGPORT} user=${RPLUSER} application_name=${appname}" \
    --recovery-option="primary_slot_name=${slot}" \
    | tee -a "$LOG_FILE"

  # Double-ensure expected files/values exist (useful if tooling versions differ).
  ensure_standby_signal
  ensure_restore_command
  ensure_primary_conninfo "$appname"
  ensure_primary_slot_name "$slot"
}

# pg_basebackup path — universal fallback. We still override -R defaults to ensure the right users/values.
restore_via_pg_basebackup(){
  need_cmd pg_basebackup
  local host="${1:-$ACTIVE_PRIMARY}" appname="$2" slot="$3"

  log "Using pg_basebackup from active primary ${host} into $PGDATA ..."
  "$PGBIN/pg_basebackup" \
    -h "${host}" -p "${PGPORT}" -U "${PGUSER}" \
    -D "${PGDATA}" -R -X stream --progress --verbose | tee -a "$LOG_FILE"

  # -R creates standby.signal and a default primary_conninfo using PGUSER. We override to RPLUSER.
  ensure_restore_command
  ensure_primary_conninfo "$appname"
  ensure_primary_slot_name "$slot"
}

# pg_rewind path — fastest for rejoining the old primary after failover (if WAL page hints or checksums enabled).
rewind_old_primary(){
  need_cmd pg_rewind
  local host="${1:-$ACTIVE_PRIMARY}"
  log "Running pg_rewind on OLD PRIMARY to follow NEW PRIMARY (${host}) ..."
  "$PGBIN/pg_rewind" \
    -D "${PGDATA}" -R \
    --source-server="host=${host} port=${PGPORT} user=${PGUSER} dbname=postgres application_name=$(hostname)-rewind" \
    | tee -a "$LOG_FILE"

  # After rewind, we still set restore_command for archive-get coverage (safer catch-ups).
  ensure_restore_command
}

# -------------------------
# HEALTH / VALIDATION
# -------------------------
# Quick reachability check to fail early if we cannot talk to the expected primary host.
validate_primary_ready(){
  log "Checking PRIMARY ${PRIMARY_IP}:${PGPORT} is reachable..."
  psql_exec "$PRIMARY_IP" "select now()" >/dev/null || die "Cannot connect to PRIMARY ${PRIMARY_IP}:${PGPORT}."
}

# Show operators what to look at after a start. We don't enforce here; this is guidance.
post_start_checks(){
  log "Post-start checks:"
  mc_status
  log "SQL quick checks you can run:"
  log "  select pg_is_in_recovery();"
  log "  select status, receive_start_lsn, latest_end_lsn from pg_stat_wal_receiver;"
}

# -------------------------
# SCENARIOS
# -------------------------
# Scenario 1: Rebuild the designated standby node from the active primary.
scenario_rebuild_standby(){
  log "=== Scenario 1: Rebuild STANDBY on this node ==="
  is_local_standby || log "WARNING: This node IP doesn't match STANDBY_IP (${STANDBY_IP}). Proceeding anyway."

  validate_primary_ready
  detect_active_primary   # usually resolves to PRIMARY_IP in a steady state

  local SLOT="$(resolve_slot_name)"
  local APPNAME="standby"
  log "Using replication slot: ${SLOT} ; application_name: ${APPNAME}"

  ensure_mc_stopped 60

  # Prefer pgBackRest; fall back to pg_basebackup if needed.
  if command -v "$PGBR_BIN" >/dev/null 2>&1; then
    # NOTE: pgBackRest restore with --delta/--force can reuse structure; wiping first is not required.
    # wipe_pgdata
    if ! restore_via_pgbackrest "$APPNAME" "$SLOT"; then
      log "pgBackRest restore failed, falling back to pg_basebackup..."
      wipe_pgdata
      restore_via_pg_basebackup "$ACTIVE_PRIMARY" "$APPNAME" "$SLOT"
    fi
  else
    log "pgBackRest not found; using pg_basebackup..."
    wipe_pgdata
    restore_via_pg_basebackup "$ACTIVE_PRIMARY" "$APPNAME" "$SLOT"
  fi

  ensure_physical_slot_on_primary "$SLOT"

  log "Starting MC (and instance) on standby..."
  mc_start "enable-failover"

  post_start_checks
  log "Standby rebuild completed."
}

# Scenario 2: After failover, turn the OLD PRIMARY into the new standby.
scenario_rebuild_old_primary(){
  log "=== Scenario 2: Rebuild OLD PRIMARY (this node) as NEW STANDBY ==="
  is_local_primary || log "WARNING: This node IP doesn't match PRIMARY_IP (${PRIMARY_IP}). Proceeding anyway."

  # After failover, the OTHER node should be the active primary, so detect again.
  detect_active_primary

  local SLOT="$(resolve_slot_name)"
  local APPNAME="standby"
  log "Using replication slot: ${SLOT} ; application_name: ${APPNAME}"

  ensure_mc_stopped 60

  # Try the fast path (pg_rewind) first. If it can't work, fall back to full restore.
  local rewind_ok=0
  if command -v "$PGBIN/pg_rewind" >/dev/null 2>&1; then
    set +e
    rewind_old_primary "$ACTIVE_PRIMARY"
    local rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      rewind_ok=1
      log "pg_rewind succeeded."
      # We still enforce our preferred recovery settings.
      ensure_primary_conninfo "$APPNAME"
      ensure_primary_slot_name "$SLOT"
	  ensure_physical_slot_on_primary "$SLOT"
    else
      log "pg_rewind failed (common reasons: wal_log_hints=off and checksums disabled). Doing full restore."
    fi
  else
    log "pg_rewind not found; performing full restore path..."
  fi

  if [[ $rewind_ok -ne 1 ]]; then
    if command -v "$PGBR_BIN" >/dev/null 2>&1; then
      # wipe_pgdata  # optional with pgBackRest, but safest to start fresh if unsure
      if ! restore_via_pgbackrest "$APPNAME" "$SLOT"; then
        log "pgBackRest restore failed, falling back to pg_basebackup..."
        wipe_pgdata
        restore_via_pg_basebackup "$ACTIVE_PRIMARY" "$APPNAME" "$SLOT"
      fi
    else
      log "pgBackRest not found; using pg_basebackup..."
      wipe_pgdata
      restore_via_pg_basebackup "$ACTIVE_PRIMARY" "$APPNAME" "$SLOT"
    fi
    ensure_physical_slot_on_primary "$SLOT"
  fi

  log "Starting MC (and instance) on rebuilt old primary (now standby)..."
  mc_start "enable-failover"

  post_start_checks
  log "Old primary successfully rebuilt as standby."
}

# -------------------------
# MAIN
# -------------------------
main(){
  [[ $# -eq 1 ]] || { echo "Usage: $0 <rebuild-standby|rebuild-old-primary>"; exit 2; }

  # Sanity checks — fail fast if key tools are missing.
  need_cmd awk
  need_cmd sed
  need_cmd psql
  need_cmd mc_ctl

  log "Log file: $LOG_FILE"
  log "PGBIN=$PGBIN  PGDATA=$PGDATA  MCDIR=$MCDIR"
  log "PRIMARY_IP=$PRIMARY_IP  STANDBY_IP=$STANDBY_IP  PGPORT=$PGPORT  PGUSER=$PGUSER  RPLUSER=$RPLUSER"
  log "PGBR_BIN=$PGBR_BIN  PGBR_STANZA=$PGBR_STANZA"

  case "$1" in
    rebuild-standby)      scenario_rebuild_standby ;;
    rebuild-old-primary)  scenario_rebuild_old_primary ;;
    *) die "Unknown action '$1'. Use: rebuild-standby | rebuild-old-primary" ;;
  esac
}

main "$@"