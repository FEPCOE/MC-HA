This folder contains example scripts that assist in the development of automating failover recovery with the FEP Mirroring Controller component.

During automatic failover, the failed primary server need to be fenced, to prevent the split-brain scenario.
To fence the primary server, sample scripts are made available with Server Assistant software. 
These sample scripts power off the primary server using IPMI tool, in case of physical server hosted on-prem.
When the database servers are hosted in the cloud (AWS or MS Azure), these sample scripts shutdown the VM using cloud CLI.

Sample fencing scripts are located at:
/installDir/fsepv<x>assistant/share/mcarb_execute_fencing.sh.sample            # For on-prem using IPMI tool
/installDir/fsepv<x>assistant/share/mcarb_execute_fencing.sh.aws.sample        # For AWS cloud
/installDir/fsepv<x>assistant/share/mcarb_execute_fencing.sh.az.sample         # For MS Azure cloud
