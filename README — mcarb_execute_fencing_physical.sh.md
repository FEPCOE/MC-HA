README — mcarb_execute_fencing_physical.sh
==========================================

## **⚠️ Disclaimer⚠️**
This script and README files are provided as examples only. They are intended to illustrate possible automation approaches for Fujitsu Enterprise Postgres environments.

**Important Note:** Use these at your own discretion. You are responsible for validating that any modifications, parameters, or procedures derived from these examples meet your operational, security, and compliance requirements. No warranty is provided, either expressed or implied, for the correctness, completeness, or suitability of these scripts for production use.

## 1	Overview
mcarb_execute_fencing_physical.sh is a custom fencing script used by the Mirroring Controller (MC) arbitration server for Fujitsu Enterprise Postgres (FEP) running on physical servers.
**The script implements two fencing layers:**

•	Soft Fencing (Preferred — Instance-Level)

•	Hard Fencing (Last Resort — Hardware Power-Off)

### 1.1	Soft Fencing (Preferred — Instance-Level)

Executed via SSH to the affected DB host:

  •	Force-stop the MC process (MC-only)
<pre>mc_ctl stop -m &lt;&lt;MCDIR&gt;&gt; -e</pre>
  
  •	Force-stop the PostgreSQL instance
<pre>pg_ctl stop -m immediate -D &lt;&lt;PGDATA&gt;&gt;</pre>
 
  •	Verify no remaining MC/PG processes for the specific FEP version (e.g., FEP16).

This ensures only the failing FEP version is fenced (e.g., FEP 16), without affecting other installed FEP versions on the same host (e.g., FEP 13).

### 1.2	B. Hard Fencing (Last Resort — Hardware Power-Off)
If soft fencing fails (SSH unreachable or verification fails), the script powers off the entire physical server via BMC/IPMI:
<pre>ipmitool -H &lt;&lt;BMCIP&gt;&gt; -U &lt;&lt;USER&gt;&gt; -P &lt;&lt;PASS&gt;&gt; chassis power off</pre> This prevents split-brain even if the OS is completely unresponsive. 
Where BMC is stands for Baseboard Management Controller. This is a small hardware chip inside physical servers and used for remote hardware control, even when:

  •	OS is down
  
  •	Server is hung
  
  •	Network is broken
  
  •	Power is partially off

### 1.3	Architecture Reference

| **Role**       | **Host IP** | **Description**                     |
|----------------|-------------|-------------------------------------|
| Arbitration    | 10.1.0.19   | MC Arbitration / Server Assistant   |
| Primary        | 10.1.0.21   | Active node (accepts writes)        |
| Standby        | 10.1.0.20   | Replica node following primary      |

## 2	How MC Calls This Script
MC automatically invokes this script during arbitration something like below and no need to provide any value manually.
<pre>mcarb_execute_fencing_physical.sh monitor switch server1</pre>
Where
| **Parameter** | **Meaning**                              | **Provided By** |
|---------------|-------------------------------------------|------------------|
| `$1`          | Trigger: `monitor` or `command`           | MC               |
| `$2`          | Action: `switch` or `detach`              | MC               |
| `$3`          | Logical server ID (`server1` or `server2`)| MC               |

## 3	Deployment and Configuration

**on Arbitration Server 10.1.0.19:**
<pre>/opt/fep/mc/share/mcarb_execute_fencing_physical.sh</pre>

Edit the arbitration.conf to configure below parameter:
<pre>fencing_command = /opt/fep/mc/share/mcarb_execute_fencing_physical.sh</pre>

Before using this fencing script, you must ensure that the arbitration server’s execution user (the user running the MC arbitration process) has execute permissions on the fencing script.
The arbitration server cannot run the fencing script unless the OS permissions allow it.

## 4	Configuration Parameters to Edit
| **Variable**       | **Example**                                 | **Description**                         |
|--------------------|----------------------------------------------|-----------------------------------------|
| `srv1ident`        | `"server1"`                                  | Logical name (from `network.conf`)      |
| `srv2ident`        | `"server2"`                                  | Logical name (from `network.conf`)      |
| `srv1addr`         | `10.1.0.20`                                  | OS IP of server1                        |
| `srv2addr`         | `10.1.0.21`                                  | OS IP of server2                        |
| `srv1bmc`          | `192.0.4.100`                                | BMC IP for server1                      |
| `srv2bmc`          | `192.0.4.110`                                | BMC IP for server2                      |
| `ipmi_admin`       | `fsepuser`                                   | BMC login user                          |
| `ipmi_password`    | `fsepuser`                                   | BMC password                            |
| `ipmi_cmd`         | `/usr/bin/ipmitool`                          | Path to `ipmitool`                      |
| `ssh_user`         | `fsepuser`                                   | SSH user on DB node                     |
| `ssh_timeout`      | `10`                                         | Timeout in seconds                      |
| `ssh_opts`         | auto-generated                               | SSH options                             |
| `remote_mc_ctl`    | `/opt/fsepv16server64/mc/bin/mc_ctl`         | MC controller binary                    |
| `remote_mc_dir`    | `/mc_fep16`                                  | MC working directory                    |
| `remote_pgctl`     | `/opt/fsepv16server64/bin/pg_ctl`            | `pg_ctl` binary                         |
| `remote_pgdata`    | `/database/fep16/inst1`                      | `PGDATA`                                |

## 5	Execution Flow
### 5.1	Step 1 — MC decides which node to fence
For example, MC decides server1 is unhealthy.

MC calls like below in background:
<pre>mcarb_execute_fencing_physical.sh monitor switch server1 </pre>

Script resolves:

  •	server1 → host 10.1.0.20

  •	server1 → BMC 192.0.4.100

### 5.2	Step 2 — Soft Fencing

•	Precheck via SSH → retrieve MC/PG status

<pre>mc_ctl stop -m &lt;&lt;MCDIR&gt;&gt; -e</pre>

<pre>pg_ctl stop -m immediate -D &lt;&lt;PGDATA&gt;&gt;</pre>

•	Verify no MC/PG processes left

If the soft-fencing succeed it means the script can reach the target host via SSH, force-stop the MC and FEP processes, and verify that no FEP16 processes remain  then the fencing operation is considered complete, and MC can safely proceed with promotion of the surviving node.

If the target host is unreachable over SSH, or if the soft-fencing actions fail or cannot be verified, the script automatically escalates to hard fencing, where the physical server is powered off through its BMC/IPMI controller as below to guarantee isolation and prevent split-brain.

### 5.3	Step 3 — Hard Fencing
Run:
<pre> ipmitool -H &lt;&lt;BMCIP&gt;&gt; -U &lt;&lt;USER&gt;&gt; -P &lt;&lt;PASS&gt;&gt; chassis power off </pre>
This physically powers off the server.

### 6	Safety Notes
•	Ensure correct BMC IPs — incorrect setting can shut down wrong server

•	Always test in non-production first

•	Ensure SSH is passwordless or uses keys

•	MC interprets exit code 0 as “safe to promote”

