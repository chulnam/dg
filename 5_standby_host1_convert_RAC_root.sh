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
echo "DB Name is..............................." $DB_NAME
echo "****************************************************************************************"

}

get_instance_names(){
export B_SID1=${DB_NAME}1
export B_SID2=${DB_NAME}2

echo "Secondary DB instance names are..............................." ${B_SID1}, ${B_SID2}
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

if [[ $tnsping_primresult = *OK* ]] && [[ $tnsping_secresult = *OK* ]] 
	then
	echo "All good for tns connections!"
	return 0
else
	echo "Issues in connection"
	return 1
fi

}


create_pfile_from_spfile() {
echo "Creating pfile from spfile to prepare for RAC..."
su oracle -c "sqlplus / as sysdba <<EOF
create pfile='/tmp/p_pre_RAC.ora' from spfile;
exit;
EOF
"
}

prepare_pfile_to_RAC() {
# From  *.cluster_database=FALSE        to       *.cluster_database=TRUE
# From  *.instance_name='ORCL1'   to:
#   ORCL1.instance_name='ORCL1'
#   ORCL2.instance_name='ORCL2'
# From  *.local_listener='(ADDRESS=(PROTOCOL=tcp)(HOST=10.1.0.4)(PORT=1521))'    to:
#     ORCL1.local_listener='(ADDRESS=(PROTOCOL=tcp)(HOST=10.1.0.4)(PORT=1521))'                             (vip of node1)
#     ORCL2.local_listener='(ADDRESS=(PROTOCOL=tcp)(HOST=10.1.0.5)(PORT=1521))'                             (vip of node2)
su oracle -c "cp /tmp/p_pre_RAC.ora /tmp/p_for_RAC.ora"
export B_LOCAL_LISTENER2="(ADDRESS=(PROTOCOL=tcp)(HOST=${B_VIP2})(PORT=${B_PORT}))"

sed -i "/*.cluster_database=FALSE/c\*.cluster_database=TRUE" /tmp/p_for_RAC.ora
sed -i "s/*.instance_name/${B_SID1}.instance_name/g" /tmp/p_for_RAC.ora
sed -i "s/*.local_listener/${B_SID1}.local_listener/g" /tmp/p_for_RAC.ora
echo ${B_SID2}.instance_name="'"${B_SID2}"'" >> /tmp/p_for_RAC.ora
echo ${B_SID2}.local_listener="'"$B_LOCAL_LISTENER2"'"  >> /tmp/p_for_RAC.ora
}

shutdown_db() {
echo "Shutting down DB..."
su oracle -c "sqlplus / as sysdba <<EOF
shutdown immediate
EOF
"
echo "DB shut down completed!"

}

create_spfile_from_pfile() {
echo "Creating spfile from the edited pfile..."
su oracle -c "sqlplus / as sysdba <<EOF
create spfile='${B_FILE_LOC_BASE}/${B_DBNM}/PARAMETERFILE/spfile${B_DBNM}.ora' from pfile='/tmp/p_for_RAC.ora';
exit;
EOF
"  >> /tmp/dataguardit.$dt.log
rm -f /tmp/p_pre_RAC.ora
rm -f /tmp/p_for_RAC.ora
}

remove_database_from_crs(){
echo "Removing database from CRS..."
su oracle -c "$ORACLE_HOME/bin/srvctl stop database -db ${B_DBNM}"
su oracle -c "$ORACLE_HOME/bin/srvctl remove database -db ${B_DBNM} -noprompt" 
echo "Database removed!"
}


add_database_to_crs(){
echo "Adding standby DB to CRS..."
export RACNODE1=`su - grid -c "olsnodes | sed -n 1p"`
export RACNODE2=`su - grid -c "olsnodes | sed -n 2p"`

su oracle -c "srvctl add database -db ${B_DBNM} -oraclehome $ORACLE_HOME"
su oracle -c "srvctl add instance -db ${B_DBNM} -instance ${B_SID1} -node $RACNODE1"
su oracle -c "srvctl add instance -db ${B_DBNM} -instance ${B_SID2} -node $RACNODE2"
su oracle -c "srvctl modify database -db ${B_DBNM} -role physical_standby -spfile ${B_FILE_LOC_BASE}/${B_DBNM}/PARAMETERFILE/spfile${B_DBNM}.ora -pwfile ${B_FILE_LOC_BASE}/${B_DBNM}/PASSWORD/pw${B_DBNM}"
su oracle -c "srvctl setenv database -d ${B_DBNM} -T \"ORACLE_UNQNAME=${B_DBNM}\" "
su oracle -c "srvctl setenv database -d ${B_DBNM} -T "TZ=UTC" "

echo "Standby DB added to CRS!"
}

start_database() {
echo "Starting database..."
su oracle -c "srvctl start database -d ${B_DBNM} -o mount"
echo "Standby database started!"
}


########################################################################################################
#
########################################################################################################


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
		get_instance_names
		create_pfile_from_spfile
		prepare_pfile_to_RAC
		shutdown_db
		create_spfile_from_pfile
		remove_database_from_crs
		add_database_to_crs
		start_database
	else
        	echo "Something went wrong. Could not configure secondary middle tier for DR!"
	fi
else
	echo "ERROR: Could not establish the required connections to primary or standby. Can't proceed!"
	echo "Is this is an OCI environment check that VCNs and subnet rules are correct, also verify your iptables"
	echo "RAC Dataguard across regions require Remote Peering in OCI"
fi


