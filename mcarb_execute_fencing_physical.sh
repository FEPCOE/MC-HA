#!/bin/sh
#
# mcarb_execute_fencing_physical.sh  (for FEP 16 MC on PHYSICAL servers)
# Author: Kothari Nishchay
#
# PURPOSE
#   Fencing command used by the Mirroring Controller (MC) arbitration server.
#
#   This script is designed for a host that may run multiple FEP versions
#   (e.g., FEP 13 and FEP 16). It performs fencing ONLY for the FEP 16
#   instance identified by remote_mc_dir/remote_pgdata. Other FEP versions
#   on the same box are not touched.
#
#   SOFT FENCING (instance-level, preferred):
#     - Over SSH to the DB host:
#         1) Force-stop MC ONLY: mc_ctl stop -M <MCDIR> -e
#         2) Force-stop DB:      pg_ctl stop -m immediate -D <PGDATA>
#         3) Verify no FEP16 MC/PG processes left.
#
#   HARD FENCING (host-level, last resort):
#     - If soft fencing fails (e.g., SSH unreachable or processes still alive),
#       power off the PHYSICAL server via IPMI/BMC:
#         ipmitool -H <BMC-IP> ... chassis power off
#
# HOW MC CALLS THIS SCRIPT
#   This script is invoked by the MC arbitration process via fencing_command:
#     fencing_command = /opt/fep/mc/share/mcarb_execute_fencing_physical.sh
#
#   MC passes three parameters automatically:
#     $1 = trigger   : 'monitor' or 'command'
#     $2 = action    : 'switch' or 'detach'
#     $3 = server id : 'server1' or 'server2' (from network.conf)
#
#   You NEVER call this script manually with parameters in production.
#   MC decides which logical server id (server1/server2) to fence and passes $3.
#
# RETURN CODES
#   0 = success (FEP16 instance safely fenced; host may or may not be powered off)
#   1 = failure (fencing could not be guaranteed)
#

# ========== SECTION 1: ENVIRONMENT SETTINGS (EDIT THESE) ==========
# All parameters in this section MUST be reviewed and adjusted
# according to your environment before using the script in production.

# Logical server identifiers (must match the first column in network.conf)
# Example network.conf entries:
#   server1 10.1.0.20,10.1.254.21 27540,27541 server
#   server2 10.1.0.21,10.1.254.22 27540,27541 server
srv1ident="server1" # Adjust according to your environment
srv2ident="server2" # Adjust according to your environment

# OS IPs of DB hosts (used for SSH from the arbiter to the DB nodes)
# These are the primary OS IPs used to log into the Linux hosts.
srv1addr="10.1.0.20" # Adjust according to your environment
srv2addr="10.1.0.21" # Adjust according to your environment

# BMC/IPMI addresses (management IPs for hardware controllers)
# These are NOT the OS IPs; they are the IPs for iRMC/iLO/iDRAC (out-of-band mgmt).
# They allow the script to power off the server even if Linux/SSH is dead.
srv1bmc="192.0.4.100"    # iRMC/iLO/iDRAC for server1 (adjust)
srv2bmc="192.0.4.110"    # iRMC/iLO/iDRAC for server2 (adjust)

# IPMI/BMC credentials and ipmitool binary
ipmi_admin="fsepuser"        # IPMI login user (adjust)
ipmi_password="fsepuser"     # IPMI password (adjust)
ipmi_cmd="/usr/bin/ipmitool" # Path to ipmitool (adjust if needed)

# SSH settings (to DB OS)
# ssh_user     : OS user used to SSH into the DB hosts; must have permission to run
#                mc_ctl and pg_ctl for the target FEP16 instance.
# ssh_timeout  : ConnectTimeout in seconds; how long SSH will wait for TCP connect.
#                If the host is unreachable, SSH fails quickly and script escalates
#                to hard fencing.
ssh_user="fsepuser" # Adjust according to your environment
ssh_timeout=10      # SSH ConnectTimeout in seconds (adjust as needed)
ssh_opts="-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=${ssh_timeout}"

# FEP16 MC & DB paths on DB hosts  ***ADJUST THESE***
# These paths are all on the DB hosts (10.1.0.20 / 10.1.0.21), NOT on the arbiter.
remote_mc_ctl="/opt/fsepv16server64/mc/bin/mc_ctl"   # Path to FEP16 mc_ctl on DB host
remote_mc_dir="/mc_fep16"                            # MCDIR for FEP16 instance
remote_pgctl="/opt/fsepv16server64/bin/pg_ctl"       # Path to FEP16 pg_ctl on DB host
remote_pgdata="/database/fep16/inst1"                # PGDATA for FEP16 instance

# Logging directory on arbiter (not on DB host)
# Script writes a separate log file per execution with a timestamped name.
logdir="/var/tmp/work"
[ -d "${logdir}" ] || mkdir -p "${logdir}"
logfile="${logdir}/fencing.$(date '+%Y%m%d%H%M%S').log"

# Marker directory on arbiter to record that fencing occurred.
# This is useful for troubleshooting and audits.
fence_marker_dir="/var/tmp/mc_fencing"
[ -d "${fence_marker_dir}" ] || mkdir -p "${fence_marker_dir}"

# SRV identifier passed by MC as third parameter (server1/server2)
srvident=$3

# ========== SECTION 2: COMMON HELPERS ==========

# putlog: append a timestamped message to the log file on arbiter.
putlog() {
    local str="$1"
    local now
    now=$(date '+%Y/%m/%d %H:%M:%S')
    echo "${now} ${str}" >> "${logfile}"
}

# start: log script start with all original parameters.
start() {
    putlog "START physical fencing params='$*'"
}

# finish: log exit code and terminate script with that code.
finish() {
    local ec="$1"
    putlog "EXIT code=${ec}"
    exit "${ec}"
}

# run_remote: run a command on the remote DB host over SSH.
# - $1: host (e.g., 10.1.0.20)
# - $2: command string to execute
# Returns:
#   - exit code of ssh (and the remote command).
run_remote() {
    local host="$1"
    local cmd="$2"
    local rc

    # Append all remote output to the same log file for troubleshooting.
    ssh ${ssh_opts} "${ssh_user}@${host}" "${cmd}" >> "${logfile}" 2>&1
    rc=$?
    return ${rc}
}

# remote_status_cmd:
#   This snippet is sent to the remote DB host.
#   It checks:
#     - if any postgres processes are running for remote_pgdata (PG_UP)
#     - if any mc_agent processes are running for remote_mc_dir (MC_UP)
#   and prints a single STATUS line for the log.
remote_status_cmd="
PG_UP=DOWN
MC_UP=DOWN
if ps -ef | grep postgres | grep -F '${remote_pgdata}' | grep -v grep >/dev/null 2>&1; then
    PG_UP=UP
fi
if ps -ef | grep mc_agent | grep -F '${remote_mc_dir}' | grep -v grep >/dev/null 2>&1; then
    MC_UP=UP
fi
echo \"STATUS PG=\${PG_UP} MC=\${MC_UP}\"
"

# remote_fence_cmd:
#   This snippet is sent to the remote DB host to do soft fencing:
#     1) Force-stop the MC process for FEP16 only:
#            mc_ctl stop -M <MCDIR> -e
#        (-e ensures only MC, not DB, is stopped)
#     2) Force-stop the DB instance for FEP16:
#            pg_ctl stop -m immediate -D <PGDATA>
remote_fence_cmd="
echo 'FENCE: forcing MC stop (MC only) for MCDIR=${remote_mc_dir}'
${remote_mc_ctl} stop -M ${remote_mc_dir} -e
echo 'FENCE: forcing DB stop (immediate) for PGDATA=${remote_pgdata}'
${remote_pgctl} stop -m immediate -D ${remote_pgdata}
"

# remote_verify_cmd:
#   This snippet verifies that no FEP16-related processes remain:
#     - No postgres processes with this PGDATA
#     - No mc_agent processes with this MCDIR
#   It prints lists of remaining processes (if any), then:
#     - exits 0 if both are empty
#     - exits 1 otherwise
remote_verify_cmd="
PG_PROCS=\$(ps -ef | grep postgres | grep -F '${remote_pgdata}' | grep -v grep || true)
MC_PROCS=\$(ps -ef | grep mc_agent | grep -F '${remote_mc_dir}' | grep -v grep || true)
echo 'VERIFY FEP16 PROCESSES:'
echo 'Postgres:'
echo \"\${PG_PROCS}\"
echo 'MC:'
echo \"\${MC_PROCS}\"
if [ -z \"\${PG_PROCS}\" ] && [ -z \"\${MC_PROCS}\" ]; then
    exit 0
else
    exit 1
fi
"

# precheck_status:
#   Runs remote_status_cmd via SSH to classify remote state:
#     - PG_UP / PG_DOWN
#     - MC_UP / MC_DOWN
#   This helps identify whether we are in scenario:
#     1) PG up, MC up
#     2) PG down, MC up
#     3) PG down, MC down
#   If SSH fails, we treat this as "host unreachable" and escalate to hard fence.
precheck_status() {
    local host="$1"
    local rc

    putlog "PRECHECK: querying PG/MC status on host=${host}"
    run_remote "${host}" "${remote_status_cmd}"
    rc=$?
    if [ ${rc} -ne 0 ]; then
        # SSH error (timeout/unreachable) or remote failure
        putlog "PRECHECK: FAILED (SSH error rc=${rc}) host=${host}"
        return 1
    fi
    putlog "PRECHECK: status retrieved for host=${host}"
    return 0
}

# Soft fencing (instance-level)
#   This function implements the full "soft" path:
#     1) precheck_status()
#     2) remote_fence_cmd for MC + DB
#     3) remote_verify_cmd to confirm no FEP16 processes remain
#
#   Returns:
#     0 = soft fencing succeeded (instance-level fence complete)
#     1 = soft fencing failed (remote verify still sees processes or other error)
#     2 = host unreachable (SSH error during precheck) → escalate to hard fence
fence_instance_soft() {
    local host="$1"
    local rc

    putlog "SOFT FENCE: starting for host=${host}"

    # Precheck PG/MC status for logging and to catch SSH-unreachable early.
    if ! precheck_status "${host}"; then
        # SSH couldn't reach the host; treat as "unreachable".
        putlog "SOFT FENCE: host unreachable during PRECHECK, escalate"
        return 2   # special: unreachable
    fi

    # Execute MC+DB forced stop on remote host.
    putlog "SOFT FENCE: execute MC+DB stop on host=${host}"
    run_remote "${host}" "${remote_fence_cmd}"
    rc=$?
    putlog "SOFT FENCE: remote fence rc=${rc} (ignored, will verify)"

    # Verify that no FEP16 processes are left.
    putlog "SOFT FENCE: verifying no FEP16 processes on host=${host}"
    run_remote "${host}" "${remote_verify_cmd}"
    rc=$?

    if [ ${rc} -eq 0 ]; then
        # No processes remain: FEP16 for this host is fully fenced.
        putlog "SOFT FENCE: verification SUCCESS on host=${host}"
        echo "$(date '+%Y/%m/%d %H:%M:%S') fenced_by_mc_soft" \
            > "${fence_marker_dir}/fep16_${host}.flag"
        return 0
    fi

    # Some FEP16 processes are still running or verify failed.
    putlog "SOFT FENCE: verification FAILED on host=${host} rc=${rc}"
    return 1
}

# Hard fencing (IPMI power-off)
#   This function is called when:
#     - host was unreachable over SSH (soft rc=2), or
#     - soft fencing verification failed (soft rc=1).
#
#   It communicates directly with the BMC/IPMI controller of the physical server,
#   which is independent of the OS, and issues a power-off.
fence_instance_hard() {
    local bmc="$1"
    local rc
    local istat

    putlog "HARD FENCE: IPMI power-off via BMC=${bmc}"

    # Optional: log current power status before issuing power-off.
    istat=$(${ipmi_cmd} -H "${bmc}" -U "${ipmi_admin}" -P "${ipmi_password}" chassis power status 2>&1)
    rc=$?
    putlog "HARD FENCE: current power status='${istat}' rc=${rc}"

    # Issue power-off command to BMC.
    istat=$(${ipmi_cmd} -H "${bmc}" -U "${ipmi_admin}" -P "${ipmi_password}" chassis power off 2>&1)
    rc=$?
    if [ ${rc} -ne 0 ]; then
        # Could not power off the server; fencing is not guaranteed.
        putlog "HARD FENCE: FAILED power off rc=${rc} msg='${istat}'"
        return 1
    fi

    putlog "HARD FENCE: power-off issued successfully to BMC=${bmc}"
    echo "$(date '+%Y/%m/%d %H:%M:%S') fenced_by_mc_hard" \
        > "${fence_marker_dir}/fep16_bmc_${bmc}.flag"
    return 0
}

# ========== SECTION 3: MAIN ==========

# Trap common signals so we log if the script is killed by a signal.
trap 'putlog "RECEIVED signal, aborting"; exit 2' 1 2 3 6 7 11 13 15

start "$@"

# Map the logical server id (server1/server2) to:
#   - target_address: OS IP (for SSH soft fencing)
#   - target_bmc    : BMC IP (for IPMI hard fencing)
case "${srvident}" in
    "${srv1ident}")
        target_address="${srv1addr}"
        target_bmc="${srv1bmc}"
        ;;
    "${srv2ident}")
        target_address="${srv2addr}"
        target_bmc="${srv2bmc}"
        ;;
    *)
        # If MC passed an unknown server identifier, we cannot proceed safely.
        putlog "ERROR: unknown server identifier '${srvident}'"
        finish 1
        ;;
esac

putlog "TARGET: srvident='${srvident}' host='${target_address}' BMC='${target_bmc}'"

# First attempt: SOFT FENCING (instance-level only).
fence_instance_soft "${target_address}"
soft_rc=$?

case "${soft_rc}" in
    0)
        # Soft fencing succeeded: MC+DB for this FEP16 instance are fully stopped,
        # and verification confirmed no related processes remain.
        # No need for hard fencing.
        putlog "COMPLETED: SOFT fencing (physical) for ${srvident}"
        finish 0
        ;;
    2)
        # Special code: host unreachable via SSH → escalate to HARD fencing.
        putlog "INFO: SOFT fencing unreachable, escalate to HARD"
        ;;
    *)
        # soft_rc=1 or any other non-zero: soft fencing attempted, but verification
        # failed or could not guarantee that all processes are down.
        # For safety, escalate to HARD fencing.
        putlog "ERROR: SOFT fencing failed, escalate to HARD"
        ;;
esac

# Second attempt: HARD FENCING (host-level power off via IPMI/BMC).
if fence_instance_hard "${target_bmc}"; then
    putlog "COMPLETED: HARD fencing (physical) for ${srvident}"
    finish 0
else
    putlog "ERROR: HARD fencing FAILED for ${srvident}"
    finish 1
fi
