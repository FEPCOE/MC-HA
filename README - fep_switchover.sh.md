README — fep_switchover.sh
=========================
## **⚠️ Disclaimer⚠️**

This script and README files are provided as examples only. They are intended to illustrate possible automation approaches for Fujitsu Enterprise Postgres environments.

**Important Note:** Use these at your own discretion. You are responsible for validating that any modifications, parameters, or procedures derived from these examples meet your operational, security, and compliance requirements. No warranty is provided, either expressed or implied, for the correctness, completeness, or suitability of these scripts for production use.

## **1	Overview**

fep_switchover.sh automates a planned role swap (switchover) between PRIMARY and STANDBY in a Fujitsu Enterprise Postgres (FEP) streaming replication setup. It ensures that the transition happens safely, consistently, and with optional Mirroring Controller (MC) refresh.

### **1.1	Functions and Flow**

1.	Verify SSH reachability and PostgreSQL role correctness.
2.	Wait for standby to catch up (WAL replay).
3.	Promote standby to new PRIMARY.
4.	Stop (fence) old primary to prevent split-brain.
5.	Ensure replication slot exists on new primary.
6.	Rewind old primary to new timeline using pg_rewind.
7.	Reconfigure old primary as standby following the new primary.
8.	Start it and verify replication is re-established.
9.	Post tasks: CHECKPOINT, apply synchronous_standby_names, and refresh MC services.

## **2	Pre‑Requisites**

The items below must be configured correctly to prevent failures during script execution.

### **2.1	OS Passwordless SSH (MANDATORY)**

The script executes remote commands via SSH — no passwords should be prompted. 

### **2.2	PostgreSQL Environment**

•	Ensure following binaries exist and are accessible on both nodes:pg_ctl, pg_rewind, psql

•	REPL_USER must have REPLICATION and LOGIN privileges.

•	For systemd‑managed instances, fsepuser must have passwordless sudo for: sudo systemctl start|stop fep@...

### **2.3	Mirroring Controller (Optional)**

If using MC, ensure MC_CTL path is valid. Script will stop/start MC with --mc-only after role switch.

### **2.4	Recommended .pgpass Setup**

<pre><code>
10.1.0.20:27500:postgres:fsepuser:&lt;&lt;password&gt;&gt;
10.1.0.21:27500:postgres:fsepuser:&lt;&lt;password&gt;&gt;
10.1.0.20:27500:replication:repluser:&lt;&lt;repl_password&gt;&gt;
10.1.0.21:27500:replication:repluser:&lt;&lt;repl_password&gt;&gt;
</code></pre>





### **2.5	pg_hba.conf on both nodes**

Appropriate entries in pg_hba.conf to allow switchover operations.

## **3	Configuration — User‑Editable Parameters**

| Parameter | Example | Description |
|----------|---------|-------------|
| `PRIMARY_HOST` | 10.1.0.21 | DB hostname/IP for current primary |
| `PRIMARY_SSH_USER` | fsepuser | SSH user for primary node |
| `PRIMARY_PGDATA` | /database/inst1 | Data directory |
| `PRIMARY_PORT` | 27500 | DB port for primary |
| `STANDBY_HOST` | 10.1.0.20 | DB hostname/IP for current standby |
| `STANDBY_SSH_USER` | fsepuser | SSH user for standby node |
| `STANDBY_PGDATA` | /database/inst1 | Data directory |
| `STANDBY_PORT` | 27500 | DB port for standby |
| `REPL_USER` | repluser | Replication user |
| `PGUSER` | fsepuser | Admin user for CHECKPOINT and config changes |
| `APP_NAME` | standby | Application name for standby |
| `PRIMARY_SLOT_NAME` | repl_slot1 | Physical replication slot name |
| `PG_CTL` | /opt/fsepv15server64/bin/pg_ctl | Path to PostgreSQL control binary |
| `PG_REWIND` | /opt/fsepv15server64/bin/pg_rewind | Path to pg_rewind binary |
| `MC_CTL` | /opt/fsepv15server64/bin/mc_ctl | Path to Mirroring Controller tool |
| `MC_DIR` | /mc | Path to Mirroring Controller files |
| `SYNC_STANDBY_NAMES_VALUE` | standby | Sync policy for new primary |
| `LAG_WAIT_BYTES` | 0 | Max replication lag allowed |
| `LAG_WAIT_TIMEOUT` | 120 | Max seconds to wait for catch-up |
| `CHECKPOINT_AFTER_PROMOTION` | true | Run CHECKPOINT after role switch |
| `local ENV_WRAP="env -u LD_LIBRARY_PATH PATH` | /opt/fsepv15server64/bin:/usr/sbin:/usr/bin | Environment wrapper to ensure correct binary path. Update this path according to your installed FEP version. • FEP 14 → /opt/fsepv14server64/bin • FEP 15 → /opt/fsepv15server64/bin • FEP 16 → /opt/fsepv16server64/bin |

**Note:** Adjust **local ENV_WRAP="env -u LD_LIBRARY_PATH PATH=/opt/fsepv<xx>server64/bin:/usr/sbin:/usr/bin"** according to your environment. Additionally, all IPs, ports, PGDATA paths, users, and replication slot names according to your environment. 

## **4	Execution Modes**

### ⚠️Execution Requirement⚠️
This script must be executed from the current standby server only.
Running it from the primary node can lead to incorrect role detection and potential data inconsistency.

### **4.1	Dry‑Run Mode (no changes made)**

Validates environment, connectivity, and replication health.
<pre>./fep_switchover.sh --dry-run</pre>
Performs: - SSH verification - Role checks (pg_is_in_recovery) - WAL lag validation

### **4.2	Execute Mode (actual role swap)**

Performs full switchover with safety checks.
<pre>./fep_switchover.sh --execute</pre>

**Sequence of actions:**

1.	Promote standby (NEW PRIMARY)
2.	Stop old primary
3.	Create replication slot on new primary (optional)
4.	Run pg_rewind on old primary
5.	Configure old primary as standby
6.	Start rejoined standby
7.	Apply synchronous_standby_names, CHECKPOINT, and refresh MC

## **5	Post‑Execution Verification**

**Run from new primary:**
<pre>SELECT pg_is_in_recovery();          -- should return 'f'
SELECT * FROM pg_stat_replication;   -- should list the standby
SHOW synchronous_standby_names;      -- verify correct sync policy </pre>
**Run from new standby:**
<pre>SELECT pg_is_in_recovery();          -- should return 't' </pre>
**Verify Mirroring Controller:**
<pre><code>
/opt/fsepv&lt;&lt;xx&gt;&gt;server64/bin/mc_ctl status -M &lt;MC_DIR&gt; #Replace <MC_DIR> with your actual Mirroring Controller path. Also &lt;&lt;xx&gt;&gt; represent your actul FEP version. 

Please ensure you will get "switchable" as mirroring status.

For Example, /opt/fsepv15server64/bin/mc_ctl status -M /mc
mirroring status
-----------------
switchable
 
server_id  host_role  host       host_status  db_proc_status  disk_status
-------------------------------------------------------------------------
server1    primary    10.1.0.20  normal       normal          normal
server2    standby    10.1.0.21  normal       normal          normal
</code></pre>

## **6	Common Issues and Fixes**
| Error | Likely Cause | Resolution |
|-------|--------------|------------|
| `ssh: connect refused` | SSH not configured properly | Reconfigure passwordless SSH |
| `pg_rewind failed` | WAL hints or checksums disabled | Enable `wal_log_hints=on` or checksums |
| `psql failed` | Missing `.pgpass` entry | Fix `.pgpass` and `pg_hba.conf` |
| `MC not-switchable` | MC state desynchronized | Enable MC refresh in script |
| `Standby did not leave recovery` | Promotion failed | Check `pg_ctl promote` logs |

## **7	Best Practices**

1.  Ensure mirroring status must be "switchable" before executing script.
2.	Always run --dry-run before executing a real switchover.
3.	Ensure replication lag ≤ LAG_WAIT_BYTES before switching.
4.	Avoid running during heavy I/O or long transactions.
5.	Validate pg_rewind prerequisites (WAL hints or checksums enabled).
