##!/bin/bash

# Check that this is running by oracle user
if [ "$(whoami)" != "oracle" ]; then
        echo "Script must be run as user: oracle"
        exit -1
fi


# Load env variables
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
"  | sqlplus -s / as sysdba
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
"  | sqlplus -s $SYS_USERNAME/$SYS_USER_PASSWORD@$A_SCAN_IP1:$A_PORT/$A_SERVICE as sysdba
)
#echo $db_type
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
tnsping ${A_DBNM}
)
export tnsping_secresult=$(
tnsping ${B_DBNM}
)

export tnsping_dupresult=$(
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

if [[ $tnsping_dupresult = *OK* ]]
        then
        echo "Standby static listener for duplication reachable on alias"

else
        echo "Standby static listener for duplication cannot be reached using TNS alias. Either connectivty issues or errors in tnsnames"
        echo "Check that the listener is up in standby and that you have the correct config in tnsames"
fi


if [[ $tnsping_primresult = *OK* ]] && [[ $tnsping_secresult = *OK* ]] && [[ $tnsping_dupresult = *OK* ]]
	then
	echo "All good for tns connections!"
	return 0
else
	echo "Issues in connection"
	return 1
fi

}


configure_tns_alias(){
echo "Configuring TNS alias..."

cp $ORACLE_HOME/network/admin/tnsnames.ora $ORACLE_HOME/network/admin/tnsnames.ora.${dt}
cat >> $ORACLE_HOME/network/admin/tnsnames.ora <<EOF
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

echo "TNS alias configured!"

}

configure_dup_listener(){
echo "Configuring listener and waiting for service..."
mv $ORACLE_HOME/network/admin/listener.ora $ORACLE_HOME/network/admin/listener.ora.${dt}
cat >> $ORACLE_HOME/network/admin/listener.ora <<EOF
LISTENER_duplicate =
(DESCRIPTION =
    (ADDRESS_LIST=
        (ADDRESS = (PROTOCOL = TCP)(HOST = ${B_HOST1_NAME})(PORT = ${B_DUP_PORT})(IP = FIRST))
     )
)

SID_LIST_LISTENER_duplicate =
    (SID_LIST =
        (SID_DESC =
                (SID_NAME = ${B_SID1})
                (ORACLE_HOME = ${ORACLE_HOME})
                (ENVS = \"TNS_ADMIN=${ORACLE_HOME}/network/admin\")
                (ENVS = \"ORACLE_BASE=${ORACLE_BASE}\")
                (ENVS = \"ORACLE_UNQNAME=${B_DBNM}\")
        )
    )

EOF
$ORACLE_HOME/bin/lsnrctl stop LISTENER_duplicate >> /tmp/1_standby_host1_prepare.$dt.log
$ORACLE_HOME/bin/lsnrctl start LISTENER_duplicate >> /tmp/1_standby_host1_prepare.sh.$dt.log

sleep 60

echo "Listener configured!"

}

echo "********************************Preparing Secondary DB for Data Guard*******************************"
retrieve_dbservice
echo "Retrieving DB SYS passwod..."
retrieve_sys_password
retrieve_sys_password_result=$?
if [ "$retrieve_sys_password_result" == 1 ]
        then
	configure_dup_listener
        configure_tns_alias
        check_connectivity
        echo "********************************Primary Database Prepared for DR*******************************"
else
                echo "Invalid password. Check DB connection and credentials"
fi


