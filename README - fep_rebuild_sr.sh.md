README — fep_rebuild_sr.sh
==========================

## **⚠️ Disclaimer⚠️**

This script and README files are provided as examples only. They are intended to illustrate possible automation approaches for Fujitsu Enterprise Postgres environments.

**Important Note:** Use these at your own discretion. You are responsible for validating that any modifications, parameters, or procedures derived from these examples meet your operational, security, and compliance requirements. No warranty is provided, either expressed or implied, for the correctness, completeness, or suitability of these scripts for production use.

## **1	Overview**
fep_rebuild_sr.sh automates rebuilding and rejoining streaming replication in a Fujitsu Enterprise Postgres (FEP) cluster managed by the Mirroring Controller (MC). It ensures both database and MC states stay consistent while restoring or re‑syncing data between primary and standby nodes.

### **1.1	Supported Scenarios**
1.	Standby Rebuild — Rebuilds a failed or corrupted standby from the active primary.
    
 	  <pre>./fep_rebuild_sr.sh rebuild-standby</pre>
  
2.	Old Primary Rejoin — After a failover, rebuilds the old primary to follow the new primary.
 	  
    <pre>./fep_rebuild_sr.sh rebuild-old-primary</pre>
    
The script detects the active primary automatically and safely stops and restarts MC and PostgreSQL.

### **1.2	Architecture Reference**

| Role | Host IP | Description |
|------|---------|-------------|
| Backup Repository Host | 10.1.0.19 | Remote pgBackRest repository server |
| Primary | 10.1.0.21 | Active node (writes accepted) |
| Standby | 10.1.0.20 | Replica node following primary |

The script uses **pgBackRest**, **pg_basebackup**, or **pg_rewind** depending on which recovery path is most suitable.

### **1.3	Key Features**
1.	Auto‑detects current **active primary** using pg_is_in_recovery().
2.	Stops both **MC** and **FEP** cleanly with safety checks (PID, socket).
3.	Rebuilds using one of three methods:

      a.	**pg_rewind** — Fast rejoin for old primary after failover.
      
  	  b.	**pgBackRest restore** — Preferred full delta restore path (remote repo).
      
  	  c.	**pg_basebackup** — Fallback if pgBackRest is unavailable.
      
4.	Automatically sets recovery parameters in **postgresql.auto.conf**:

      a.	primary_conninfo
      
      b.	primary_slot_name
      
      c.	restore_command
      
5.	Ensures physical replication slot exists on primary (best‑effort).

6.	Restarts MC with the correct failover mode and provides post‑start health checks.

**Note on restore_command Handling:**

If **pgBackRest** is configured and active in the environment, the script automatically sets the restore_command parameter to use the pgBackRest restore command.

If **pgBackRest** is **not configured or not in use**, the script will skip setting the restore_command and remove it automatically if it already exists in postgresql.auto.conf to prevent startup errors.

## **2	Authentication Requirements**

### **2.1	pgBackRest (DB → Repo host)**

pgBackRest uses SSH to access the remote repository. Configure **passwordless SSH** from both DB nodes **(10.1.0.20 & 10.1.0.21)** to repo host **(10.1.0.19)**:
No SSH is needed between **10.1.0.20** and **10.1.0.21** for this script.

### **2.2	Database Connections (.pgpass)**

All DB‑to‑DB actions use .pgpass for passwordless authentication. Example entries on both nodes (chmod 600 ~/.pgpass):

<pre>
10.1.0.20:27500:postgres:fsepuser:&lt;&lt;password&gt;&gt;
10.1.0.21:27500:postgres:fsepuser:&lt;&lt;password&gt;&gt;
10.1.0.20:27500:replication:repluser:&lt;&lt;repl_password&gt;&gt;
10.1.0.21:27500:replication:repluser:&lt;&lt;repl_password&gt;&gt;
</pre>




### **2.3	pg_hba.conf (on active primary)**

Appropriate entries in pg_hba.conf to allow pg_basebackup and other recovery operations.

## **3	Configuration Parameters to Edit**
| Variable | Example | Description |
|----------|---------|-------------|
| `PRIMARY_IP` | 10.1.0.21 | Intended primary node |
| `STANDBY_IP` | 10.1.0.20 | Intended standby node |
| `PGDATA` | /database/inst1 | Data directory on this host |
| `PGBIN` | /opt/fsepv15server64/bin | PostgreSQL binary directory |
| `MCDIR` | /mc | Mirroring Controller path |
| `PGBR_BIN` | /opt/fsepv15client64/OSS/pgbackrest/bin/pgbackrest | Path to pgBackRest client |
| `PGBR_STANZA` | fep15 | Stanza name in pgBackRest |
| `PGPORT` | 27500 | Database port |
| `PGUSER` | fsepuser | Admin user for pg_rewind, psql checks |
| `RPLUSER` | repluser | Replication user for streaming |
| `SLOT_NAME` | repl_slot1 | Physical replication slot name |
| `LOG_DIR` | /home/fsepuser/scripts/log | Script log storage location |
| `APPNAME` | standby | Application name for this standby |

**Note:** Update local APPNAME="standby" and local appname="standby" inside the script according to your environment if a different application name is used.

Additionally, adjust all IPs, ports, PGDATA paths, users, and replication slot names according to your environment.

## **4	Execution Workflow**
### ⚠️Execution Requirement⚠️
This script must be executed from the current standby server only.
Running it from the primary node can lead to incorrect role detection and potential data inconsistency.

### **4.1	To Rebuild Standby**

1.	SSH into standby node (10.1.0.20).

2.	Run:
 	<pre>./fep_rebuild_sr.sh rebuild-standby</pre>

3.	The script will:

a.	Detect current primary.

b.	Stop MC/PG on standby.

c.	Restore data using pgBackRest (or pg_basebackup fallback).

d.	Reconfigure recovery and start MC.

### **4.2	To Rebuild Old Primary after Failover**

1.	SSH into the old primary (10.1.0.21).

2.	Run:
<pre>./fep_rebuild_sr.sh rebuild-old-primary</pre>

3.	The script will:

a.	Detect new active primary.

b.	Stop MC/PG locally.

c.	Attempt pg_rewind first, else fall back to pgBackRest or pg_basebackup.

d.	Restart MC and validate recovery.

## **5	Post‑Execution Checks**

**Run on the standby:**
<pre>SELECT pg_is_in_recovery();  -- should return 't'
SELECT status, receive_start_lsn, latest_end_lsn FROM pg_stat_wal_receiver;</pre>

**Also confirm via:**
<pre>/opt/fsepv15server64/bin/mc_ctl status -M &lt;MCDIR&gt; #Replace "MCDIR" with your actual Mirroring Controller path</pre>

## **6	Common Issues & Fixes**
| Error | Likely Cause | Fix |
|-------|--------------|-----|
| `requested starting point ... not in history` | Timeline diverged | Use `pg_rewind` or perform a full restore |
| `pg_rewind failed` | `wal_log_hints=off` or no checksums | Enable WAL hints or rebuild fully |
| `archive-get failed` | SSH or repository configuration issue | Verify pgBackRest SSH access and stanza |
| `could not connect to server` | Missing `.pgpass` or incorrect `pg_hba.conf` | Fix authentication entries and reload |
| `MC not-switchable` | Node still degraded | Wait for full rebuild and recheck MC state |



