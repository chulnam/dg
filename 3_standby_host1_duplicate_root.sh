#!/bin/bash

# Check that this is running by oracle root
if [ "$(whoami)" != "root" ]; then
        echo "Script must be run as user: root"
        exit -1
fi


# Load custom environment variables
. STANDBY_rac_dg.ini


retrieve_dbservice(){
export B_BASE='/u01/app/oracle'
echo "**************************SECONDARY SYTEM INFORMATION GATHERED***************************"
export B_DBNM=$ORACLE_UNQNAME
echo "Secondary DB UNIQUE NAME....................." $ORACLE_UNQNAME

export B_SERVICE_ALL=`lsnrctl status | grep $ORACLE_UNQNAME | awk -F '"' '{print $2}'`
export B_SERVICE=`echo $B_SERVICE_ALL | awk '{print $1;}'`
echo "Secondary DB Service is......................" $B_SERVICE

export B_DB_DOMAIN=`echo $B_SERVICE |awk -F '.' '{print $2"."$3"."$4"."$5}'`
echo "Secondary DB Domain is......................" $B_DB_DOMAIN

export B_PORT_ALL=`lsnrctl status | grep DESCRIPTION | grep "PORT" | awk -F 'PORT=' '{print $2}'| awk -F ')))' '{print $1}'`
export B_PORT=`echo ${B_PORT_ALL} |awk '{print $1}'`
echo "Secondary DB Port is........................" $B_PORT

echo "Secondary SCAN Host is......................" $B_SCAN_ADDRESS

export DB_NAME=$(
echo "set feed off
set pages 0
select value from V\$PARAMETER where NAME='db_name';
exit
"  | su oracle -c "sqlplus -s / as sysdba"
)
echo "Secondary DB Name is..............................." $DB_NAME
echo "****************************************************************************************"

}

retrieve_sys_password(){
export count=0;
export top=3;
while [ $count -lt  $top ]; do
echo "Enter the database SYS password: "
read -s  SYS_USER_PASSWORD
export db_type=$(
echo "set feed off
set pages 0
select database_role from v\$database;
exit
"  | su oracle -c "sqlplus -s $SYS_USERNAME/$SYS_USER_PASSWORD@$A_SCAN_IP1:$A_PORT/$A_SERVICE as sysdba"
)
if  [[ $db_type = *PRIMARY* ]]; then
        echo "Sys password is valid. Proceeding..."
        count=3
        return 1
else
   echo "Invalid password or incorrect DB status";
   echo "Check that you can connect to the DB and that it is in Data Guard PRIMARY role."
   count=$(($count+1));
   if [ $count -eq 3 ]; then
        echo "Maximum number of attempts exceeded, review you login to the DB"
        return 0
   fi
fi
done
}


check_connectivity(){
# VERIFY CONNECTIVITY BETWEEN PRIMARY AND STANDBY
export tnsping_primresult=$(
su oracle -c "tnsping ${A_DBNM}"
)
export tnsping_secresult=$(
su  oracle -c "tnsping ${B_DBNM}"
)
export tnsping_duplicate=$(
tnsping DUPLICATE
)

if [[ $tnsping_primresult = *OK* ]]
        then
        echo "Remote primary database listener reachable on alias"

else
        echo "Remote primary database cannot be reached using TNS alias. Either connectivty issues or errors in tnsnames"
	echo "Check that the listener is up in primary and that you have the correct config in tnsames"

fi

if [[ $tnsping_secresult = *OK* ]]
        then
        echo "Standby database listener reachable on alias"

else
        echo "Standby  database cannot be reached using TNS alias. Either connectivty issues or errors in tnsnames"
	echo "Check that the listener is up in standby and that you have the correct config in tnsames"
fi

if [[ $tnsping_duplicate = *OK* ]]
        then
        echo "Standby listener for duplication reachable on alias"

else
        echo "Standby listener for duplication  cannot be reached using TNS alias. Either connectivty issues or errors in tnsnames"
        echo "Check that the listener is up in standby and that you have the correct config in tnsames"
fi

if [[ $tnsping_primresult = *OK* ]] && [[ $tnsping_secresult = *OK* ]] && [[ $tnsping_duplicate = *OK* ]]
	then
	echo "All good for tns connections!"
	return 0
else
	echo "Issues in connection"
	return 1
fi

}

delete_orig_db(){
echo "Deleting existing DB..."
# For RAC cases unique name must be used
su oracle -c "$ORACLE_HOME/bin/dbca -silent -deleteDatabase -sourceDB ${B_DBNM} -sysDBAUserName $SYS_USERNAME -sysDBAPassword ${SYS_USER_PASSWORD}  -forceArchiveLogDeletion"  >> /tmp/3_standby_host1_duplicate_root.$dt.log
echo "Database deleted!"
}


shutdown_db(){
echo "Shuting down DB..."
su oracle -c "sqlplus / as sysdba <<EOF
shutdown abort
EOF
" >> /tmp/3_standby_host1_duplicate_root.$dt.log
echo "DB shut down completed!"
}


get_wallet_from_primary(){
echo "Extracting wallet..."
chown oracle:oinstall $INPUT_WALLET_TAR
su oracle -c "mv $TDE_LOC/$B_DBNM $TDE_LOC/$B_DBNM.$dt"
su oracle -c "mkdir $TDE_LOC/$B_DBNM"
cd $TDE_LOC/$B_DBNM
su oracle -c "tar -xzf $INPUT_WALLET_TAR"
su oracle -c "sqlplus / as sysdba <<EOF
ADMINISTER KEY MANAGEMENT CREATE AUTO_LOGIN KEYSTORE FROM KEYSTORE '$TDE_LOC/$B_DBNM' IDENTIFIED BY ${SYS_USER_PASSWORD};
EOF
" >> /tmp/3_standby_host1_duplicate_root.$dt.log

echo "Wallet extracted!"
}


configure_tns_alias(){
echo "Configuring TNS alias..."
su oracle -c 'cp $ORACLE_HOME/network/admin/tnsnames.ora $ORACLE_HOME/network/admin/tnsnames.ora.${dt}'
su oracle -c 'cat > $ORACLE_HOME/network/admin/tnsnames.ora <<EOF
${A_DBNM} =
  (DESCRIPTION =
    (SDU=65536)
    (RECV_BUF_SIZE=10485760)
    (SEND_BUF_SIZE=10485760)
    (ADDRESS_LIST=
    (LOAD_BALANCE=on)
    (FAILOVER=on)
    (ADDRESS = (PROTOCOL = TCP)(HOST = ${A_SCAN_IP1})(PORT = 1521))
    (ADDRESS = (PROTOCOL = TCP)(HOST = ${A_SCAN_IP2})(PORT = 1521))
    (ADDRESS = (PROTOCOL = TCP)(HOST = ${A_SCAN_IP3})(PORT = 1521)))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = ${A_SERVICE})
    )
  )
${B_DBNM} =
 (DESCRIPTION =
    (SDU=65536)
    (RECV_BUF_SIZE=10485760)
    (SEND_BUF_SIZE=10485760)
    (ADDRESS_LIST=
    (LOAD_BALANCE=on)
    (FAILOVER=on)
    (ADDRESS = (PROTOCOL = TCP)(HOST = ${B_SCAN_IP1})(PORT = 1521))
    (ADDRESS = (PROTOCOL = TCP)(HOST = ${B_SCAN_IP2})(PORT = 1521))
    (ADDRESS = (PROTOCOL = TCP)(HOST = ${B_SCAN_IP3})(PORT = 1521)))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = ${B_SERVICE})
    )
  )
DUPLICATE =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = ${B_HOST1_NAME})(PORT = ${B_DUP_PORT}))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SID = ${B_SID1})
    )
  )

EOF
'
echo "TNS alias configured!"

}

create_password_file(){
echo "Creating password file..."
cd $ORACLE_HOME/dbs
su oracle -c "$ORACLE_HOME/bin/orapwd file='$ORACLE_HOME/dbs/orapw${B_SID1}' password=${SYS_USER_PASSWORD} force=y"
echo "Password file created!"

}

start_auxiliary_db(){
echo "Starting Auxiliary DB..."
export ORACLE_SID=${B_SID1}
su oracle -c "cat > $ORACLE_HOME/dbs/init${B_SID1}.ora << EOF
db_name=${DB_NAME}
db_unique_name=${B_DBNM}
db_domain=${B_DB_DOMAIN}
sga_target=15g
EOF
"
su oracle -c "$ORACLE_HOME/bin/sqlplus / as sysdba <<EOF
startup nomount pfile='$ORACLE_HOME/dbs/init${B_SID1}.ora'
EOF
" 
}>> /tmp/3_standby_host1_duplicate_root.$dt.log

set_primary_maa(){
echo "Setting recommended MAA parameters in DB..."
su oracle -c "$ORACLE_HOME/bin/sqlplus -s ${SYS_USERNAME}/${SYS_USER_PASSWORD}@${A_DBNM} as sysdba <<EOF
alter database add standby logfile thread 1 group 5 '$A_REDO_LOC_DISK' size 1073741824;
alter database add standby logfile thread 1 group 6 '$A_REDO_LOC_DISK' size 1073741824;
alter database add standby logfile thread 1 group 7 '$A_REDO_LOC_DISK' size 1073741824;
alter database add standby logfile thread 2 group 8 '$A_REDO_LOC_DISK' size 1073741824;
alter database add standby logfile thread 2 group 9 '$A_REDO_LOC_DISK' size 1073741824;
alter database add standby logfile thread 2 group 10 '$A_REDO_LOC_DISK' size 1073741824;
alter database force logging;
alter database flashback on;
alter system set remote_login_passwordfile='exclusive' scope=spfile sid='*';
alter system set DB_BLOCK_CHECKSUM=FULL;
alter system set DB_LOST_WRITE_PROTECT=TYPICAL;
alter system set LOG_BUFFER=256M scope=spfile sid='*';
exit;
EOF
" >> /tmp/3_standby_host1_duplicate_root.$dt.log
echo "Primary settings applied!"

# change also these?
# alter system set DB_FLASHBACK_RETENTION_TARGET=120 scope=both sid='*'; --> current value 1440
# alter system set DB_BLOCK_CHECKING=MEDIUM;      --> current value FULL

}

remove_dataguard_broker_config(){
echo "Removing previous DGBroker configuration..."
su oracle -c "$ORACLE_HOME/bin/dgmgrl ${SYS_USERNAME}/${SYS_USER_PASSWORD}@${A_DBNM} <<EOF
remove configuration
exit
EOF
" >> /tmp/3_standby_host1_duplicate_root.$dt.log
echo "DGBroker configuration removed!"
}



create_standby_dirs(){
echo "Creating standby DIR structure..."
su oracle -c "mkdir -p $ORACLE_BASE/admin/${B_DBNM}/adump"
# these are really required? Commenting
#su oracle -c "mkdir -p $ORACLE_BASE/admin/${B_DBNM}/dpump"
#su oracle -c "mkdir -p $ORACLE_BASE/admin/${B_DBNM}/xdb_wallet"
#su oracle -c "mkdir -p $ORACLE_BASE/admin/${B_DBNM}/pfile"
#su oracle -c "mkdir -p $ORACLE_BASE/admin/${B_DBNM}/db_wallet"
#su oracle -c "mkdir -p $ORACLE_BASE/admin/${B_DBNM}/tde_wallet"
chown -R oracle:oinstall "$ORACLE_BASE/admin/${B_DBNM}/adump"
#chown -R oracle:oinstall "$ORACLE_BASE/admin/${B_DBNM}/dpump"
#chown -R oracle:oinstall "$ORACLE_BASE/admin/${B_DBNM}/db_wallet"
#chown -R oracle:oinstall "$ORACLE_BASE/admin/${B_DBNM}/pfile"

echo "Standby directories created!"
}

create_execute_dup(){
echo "Creating and running duplication script..."
echo "This may take some time. Please wait..."
cat >/tmp/${B_DBNM}.rman <<EOF
connect target ${SYS_USERNAME}/${SYS_USER_PASSWORD}@${A_SCAN_IP1}:${A_PORT}/${A_SERVICE}
connect auxiliary ${SYS_USERNAME}/${SYS_USER_PASSWORD}@DUPLICATE
run {
allocate channel prmy1 type disk;
allocate auxiliary channel stby1 type disk;
allocate auxiliary channel stby2 type disk;
allocate auxiliary channel stby3 type disk;
allocate auxiliary channel stby4 type disk;
duplicate target database for standby from active database
spfile
PARAMETER_VALUE_CONVERT= '${A_DBNM}','${B_DBNM}', '${A_DB_DOMAIN}','${B_DB_DOMAIN}','${A_DBNM,,}','${B_DBNM}'
set db_unique_name='${B_DBNM}'
set db_name='${DB_NAME}'
set instance_name='${B_SID1}'
set control_files='${B_FILE_LOC_DISK}/${B_DBNM}/control01.ctl', '${B_REDO_LOC_DISK}/${B_DBNM}/control02.ctl'
set audit_file_dest='${B_BASE}/admin/${B_DBNM}/adump'
set local_listener='(ADDRESS=(PROTOCOL=tcp)(HOST=${B_VIP1})(PORT=${B_PORT}))'
set REMOTE_LISTENER='${B_REMOTE_LISTENER}'
set CLUSTER_DATABASE='FALSE'
set fal_server='${A_DBNM}'
set log_file_name_convert='${A_REDO_LOC_DISK}','${B_REDO_LOC_DISK}','${A_REDO_LOC}','${B_REDO_LOC}'
set db_file_name_convert='${A_FILE_LOC_DISK}','${B_FILE_LOC_DISK}'
set db_create_file_dest='${B_FILE_LOC_BASE}'
set db_create_online_log_dest_1='${B_REDO_LOC_BASE}'
set db_recovery_file_dest='${B_RECOV_LOC}'
set db_recovery_file_dest_size='255G'
set diagnostic_dest='${B_BASE}'
set db_domain='$B_DB_DOMAIN'
set STANDBY_FILE_MANAGEMENT='AUTO'
NOFILENAMECHECK
section size 500M
dorecover
;
}
EOF
chmod o+r /tmp/${B_DBNM}.rman 
chown oracle:asmadmin /tmp/${B_DBNM}.rman
su oracle -c "$ORACLE_HOME/bin/rman << EOF
@/tmp/${B_DBNM}.rman
EOF
" >> /tmp/3_standby_host1_duplicate_root.$dt.log
rm /tmp/${B_DBNM}.rman
}

cp_pwfile_asm() {
echo "Copying password file to ASM..."
export DB_HOME=$ORACLE_HOME
su - grid -c "${GRID_HOME}/bin/asmcmd mkdir ${B_FILE_LOC_BASE}/${B_DBNM}/PASSWORD"
echo "Ignore failures if PASSWORD folder already exists"
su - grid -c "${GRID_HOME}/bin/asmcmd pwcopy ${DB_HOME}/dbs/orapw${B_SID1} ${B_FILE_LOC_BASE}/${B_DBNM}/PASSWORD/pw${B_DBNM}"
#rm -f $ORACLE_HOME/dbs/orapw${B_SID1} 
echo "Copied password file to ASM..."
}

cp_spfile_asm() {
echo "Creating spfile in ASM..."
export DB_
su - grid -c "$GRID_HOME/bin/asmcmd mkdir ${B_FILE_LOC_BASE}/${B_DBNM}/PARAMETERFILE"
echo "Ignore failures if PARAMETERFILE folder already exists"
su oracle -c "sqlplus ${SYS_USERNAME}/${SYS_USER_PASSWORD}@${B_DBNM} as sysdba <<EOF
create pfile='/tmp/p_after_duplication.ora' from spfile;
create spfile='${B_FILE_LOC_BASE}/${B_DBNM}/PARAMETERFILE/spfile${B_DBNM}.ora' from pfile='/tmp/p_after_duplication.ora';
exit;
EOF
"  >> /tmp/3_standby_host1_duplicate_root.$dt.log
# Remove temporal pfile .ora 
rm -f /tmp/p_after_duplication.ora
# Remove spfile from $ORACLE_HOME/dbs, to prevent mistakes. Only the spfile in ASM will be used
rm -f $ORACLE_HOME/dbs/spfile${B_SID1}.ora
echo "Creating new pfile pointing to the spfile in ASM..."
su oracle -c "cat > $ORACLE_HOME/dbs/init${B_SID1}.ora <<EOF
spfile='${B_FILE_LOC_BASE}/${B_DBNM}/PARAMETERFILE/spfile${B_DBNM}.ora' 
EOF
" >> /tmp/3_standby_host1_duplicate_root.$dt.log

}

restart_db_instance() {
echo "Restarting instance ..."
export ORACLE_SID=${B_SID1}
su oracle -c "${ORACLE_HOME}/bin/sqlplus / as sysdba <<EOF
shutdown immediate;
startup mount;
exit;
EOF
" >> /tmp/3_standby_host1_duplicate_root.$dt.log

}

# STEPS
# get_wallet_from_primary
# Delete existing secondary DB
# Create password file for standby  in $ORACLE_HOME/dbs
# Create a pfile for secondary aux in ORACLE_HOME/dbs
# Create audit folder adump
# Create an Oracle Net alias to reach the remote database (to scan listener) in each site  AGAIN becuse are deleted with db deletion
# Export SID and startup nomount the auxiliary
# Copy wallet from primary to standby
# Run an RMAN script that duplicates the primary database
# Copy the password file to respective location, which in 12.1 onwards is ASM
# Create the standby spfile in ASM
# Create init that points to the spfile created I nASM
# Restart standby instance

echo "****************************Duplicate primary DB to standbyi started************************"

retrieve_dbservice
check_connectivity
check_connectivity_result=$?
echo "****************************Connectivity check complete!*************************"
if [ "$check_connectivity_result" == 0 ] 
	then
	retrieve_sys_password
	retrieve_sys_password_result=$?
	if [ "$retrieve_sys_password_result" == 1 ]
		then
		# Get wallet before deleting the DB
		get_wallet_from_primary
		# Delete existing secondary DB
		delete_orig_db
		# For re-tries, shutting down any existing aux
		shutdown_db
                echo "********************************Clean up complete!*******************************"
                echo "*******************************Standby setup started...**************************"
		# Create an Oracle Net alias to reach the remote database (to scan listener)
		# AGAIN because theyare deleted with db deletion
		configure_tns_alias
		check_connectivity
		# Create password file for standby in $ORACLE_HOME/dbs
    		create_password_file
		# Create audit folder adump
		create_standby_dirs
		# Create a pfile for secondary aux and start nomount
		start_auxiliary_db
		# Remove DG conf from primary in case it was already set
		remove_dataguard_broker_config
		# Set MAA recommentationsfor DG in primary
		set_primary_maa
		# Run an RMAN script that duplicates the primary database
		create_execute_dup
		# Copy the password file to ASM
		cp_pwfile_asm
		# Create the standby spfile in ASM
		cp_spfile_asm
		# restart the standby database instance to use the asm spfile
		restart_db_instance
	echo "*************************Duplicate primary RAC DB to standby complete!***********************"

	else
        	echo "Something went wrong. Could not configure secondary middle tier for DR!"
	fi
else
	echo "ERROR: Could not establish the required connections to primary or standby. Can't proceed!"
	echo "Is this is an OCI environment check that VCNs and subnet rules are correct, also verify your iptables"
	echo "RAC Dataguard across regions require Remote Peering in OCI"
fi


