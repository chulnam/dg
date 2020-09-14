##!/bin/bash

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
echo "DB Name is..............................." $DB_NAME
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
#echo "TNSPING RESULT:" $tnsping_secresult
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

if [[ $tnsping_primresult = *OK* ]] && [[ $tnsping_secresult = *OK* ]]
	then
	echo "All good for tns connections!"
	return 0
else
	echo "Issues in connection"
	return 1
fi

}


remove_dataguard_broker_config(){
echo "Removing previous DGBroker configuration..."
su oracle -c "$ORACLE_HOME/bin/dgmgrl ${SYS_USERNAME}/${SYS_USER_PASSWORD}@${A_DBNM} <<EOF
remove configuration
exit
EOF
" >> /tmp/6_standby_host1_DG_conf_root.$dt.log
echo "DGBroker configuration removed!"
}


enable_flashback_standby(){
echo "Enabling flashback in standby..."
su oracle -c "sqlplus -s ${SYS_USERNAME}/${SYS_USER_PASSWORD}@${B_DBNM} as sysdba <<EOF
alter database flashback on;
exit;
EOF
" >> /tmp/6_standby_host1_DG_conf_root.$dt.log
echo "Flashback enabled in standby!"
}

create_dataguard_broker_config(){
echo "Creating new DG Broker configuraton..."
su oracle -c "$ORACLE_HOME/bin/sqlplus -s ${SYS_USERNAME}/${SYS_USER_PASSWORD}@${A_DBNM} as sysdba <<EOF
  alter system set dg_broker_start=FALSE;
  alter system set dg_broker_config_file1='${A_FILE_LOC}/dr1.dat';
  alter system set dg_broker_config_file2='${A_RECOV_LOC}/dr2.dat';
  alter system set dg_broker_start=TRUE;
  exit;
EOF
">> /tmp/6_standby_host1_DG_conf_root.$dt.log
su oracle -c "$ORACLE_HOME/bin/sqlplus -s ${SYS_USERNAME}/${SYS_USER_PASSWORD}@${B_DBNM} as sysdba <<EOF
alter system set dg_broker_start=FALSE;
alter system set dg_broker_config_file1='${B_FILE_LOC}/dr1.dat';
alter system set dg_broker_config_file2='${B_RECOV_LOC}/dr2.dat';
alter system set dg_broker_start=TRUE;
exit;
EOF
">> /tmp/6_standby_host1_DG_conf_root.$dt.log
sleep 10

su oracle -c "$ORACLE_HOME/bin/dgmgrl sys/${SYS_USER_PASSWORD}@${A_DBNM} <<EOF
create configuration '${A_DBNM}_${B_DBNM}_${dt}' as primary database is '${A_DBNM}'
  connect identifier is '${A_DBNM}';
add database '${B_DBNM}' as connect identifier is '${B_DBNM}';
EDIT CONFIGURATION SET PROTECTION MODE AS MaxPerformance;
enable configuration;
show configuration verbose
exit
EOF
">> /tmp/6_standby_host1_DG_conf_root.$dt.log

echo "New DG Broker configuration created!"
}


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
		enable_flashback_standby
		remove_dataguard_broker_config		
		create_dataguard_broker_config
		echo "Data Guard broker configuration created!"
		echo "************************ALL DONE! Check the resulting dgbroker config!*************************"
		echo "***********************************Standby setup complete!***********************************"

	else
        	echo "Something went wrong. Could not configure secondary middle tier for DR!"
	fi
else
	echo "ERROR: Could not establish the required connections to primary or standby. Can't proceed!"
	echo "If you are in an OCI-C enviornment check that the appropriate IP Networks and Rules are in place"
	echo "Is this is an OCI environment check that VCNs and subnet rules are correct, also verify your iptables"
	echo "Dataguard across regions may require Remote Peering in OCI"
fi


