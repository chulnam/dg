# dg
Setup Dataguard
####################################################
STEPS TO RUN SCRIPTS TO CONFIGURE DATAGUARD FOR RAC
####################################################

These scripts configure the Dataguard between 2 DB systems, located in different regions, that are communicated via a Dynamic Routing Gateway.

Network Pre-requisites
------------------------------
a) Configure communication between primary and secondary RACs using Dynamic Routing Gateway.
The RAC databases listen in internal IPs(scan IPs). Primary and secondary RAC needs to be able to connect each other via those internal IPs.
Configure Dynamic Routing Gateway between the primary and secondary VCNs. See Dynamic Routing Gateways (DRGs) documentation at:
https://docs.cloud.oracle.com/en-us/iaas/Content/Network/Tasks/managingDRGs.htm

b)Create security rule in primary VCN to allow connections from secondary VCN IPs to port 1521

c)Create security rule in secondary VCN to allow connections from primary VCN IPs to port 1521

d)Allow connections from primary to secondary port 1525 (duplicate port)
For the database duplication, the scripts will create an static listener in secondary db host1.
The port for this listener is configurable, although be default is set to 1525.
Be sure that you open communications from primary hosts to secondary duplicate listener port. This means:
   - Create the required security rule in seconday VCN to allow incoming connections to that port from primary db hosts.
   - Open the port in secondary db host1 iptables. Example:
   iptables-save > /tmp/iptables.orig
   iptables -I INPUT 8 -p tcp -m state --state NEW -m tcp --dport 1525 -j ACCEPT -m comment --comment "To static lister for duplication"
   service iptables status
   service iptables save


0- Prepare the property files
------------------------------------------------------------  
- Upload "PRIMARY_rac_dg.ini" file to PRIMARY db host1 and db host2, open and customize with the environment values.
- Upload "STANDBY_rac_dg.ini" file to SECONDARY db host1 and db host2,  open and customize with the environment values.

NOTE: .ini files and scripts need to be located in the same folder

1- Run "1_standby_host1_prepare.sh" 
------------------------------------------------------------
Where to run:   In SECONDARY db host1
Run with user:  oracle
This will create an static listener for the duplication in secondary host1, the required tns aliases, and check the conectivity.


2- Run "2_primary_prepare.sh" 
------------------------------------------------------------
Where to run:   In PRIMARY db host1 and host2
Run with user:  oracle
This will create required tns aliases on primary and check the conectivity.
As output, this will create the file PRI_WALLET.GZ that needs to be manually copied to secondary hosts (both hosts!)


3- Run "3_standby_host1_duplicate_root.sh"
------------------------------------------------------------
Where to run:   In SECONDARY db host1
Run with user:  root
This will duplicate primary db on secondary db (as single instance)

4- Run "4_standby_host2_prepare.sh"
------------------------------------------------------------
Where to run:   In SECONDARY db host2
Run with user:  oracle
This will create required aliases and init<sid>.ora in host2 prior to convert the duplicated database into RAC.


5- Run "5_standby_host1_convert_RAC_root.sh"
------------------------------------------------------------
Where to run:   In SECONDARY db host1
Run with user:  root
This will convert duplicated database into RAC database.

6- Run 6_standby_host1_DG_conf_root.sh
------------------------------------------------------------
Where to run:   In SECONDARY db host1
Run with user:  root
This will configure the DataGuard Broker between primary and standby.
