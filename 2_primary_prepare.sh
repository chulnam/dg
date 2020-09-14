#!/bin/bash
#2_prepare_primary.sh

# Check that this is running by oracle user
if [ "$(whoami)" != "oracle" ]; then
        echo "Script must be run as user: oracle"
        exit -1
fi

# Load environment specific variables
. PRIMARY_rac_dg.ini


retrieve_dbservice(){

echo "**************************PRIMARY SYTEM INFORMATION GATHERED***************************"

echo "Primary DB UNIQUE NAME................." $ORACLE_UNQNAME

export A_SERVICE_ALL=`lsnrctl status | grep $ORACLE_UNQNAME | awk -F '"' '{print $2}'`
export A_SERVICE=`echo ${A_SERVICE_ALL} |awk '{print $1}'`
echo "Primary DB Service is.................." $A_SERVICE

export A_PORT_ALL=`lsnrctl status | grep DESCRIPTION | grep "PORT" | awk -F 'PORT=' '{print $2}'| awk -F ')))' '{print $1}'`
export A_PORT=`echo ${A_PORT_ALL} |awk '{print $1}'`
echo "Primary DB Port is....................." $A_PORT

# This is not valid for rac. A_SCAN_ADDRESS will be used instead
#export A_CONNECT_ADDRESS_ALL=$(lsnrctl status | grep DESCRIPTION | grep "HOST" | awk -F 'HOST=' '{print $2}' | awk -F '\\)\\(PORT' '{print $1}')
#export A_CONNECT_ADDRESS=`echo ${A_CONNECT_ADDRESS_ALL} |awk '{print $1}'`
#echo "Primary DB Host is....................." $A_CONNECT_ADDRESS
echo "Primary scan address  is....................." $A_SCAN_ADDRESS

export DB_NAME=$(
echo "set feed off
set pages 0
select value from V\$PARAMETER where NAME='db_name';
exit
"  | sqlplus -s / as sysdba
)

}

retrieve_sys_password(){
export count=0;
export top=3;
while [ $count -lt  $top ]; do
echo "Enter the database SYS password: "
read -s  SYS_USER_PASSWORD
export CONNECT_STR="sqlplus -s $SYS_USERNAME/$SYS_USER_PASSWORD@$A_SCAN_ADDRESS:$A_PORT/$A_SERVICE as sysdba"
echo $CONNECT_STR
export db_type=$(
echo "set feed off
set pages 0
select database_role from v\$database;
exit
"  | $CONNECT_STR
)
#echo "THE DB TYPE IS: "$db_type
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

create_wallet_tar(){
echo "Creating wallet tar..."
cd $TDE_LOC
tar -czf ${OUTPUT_WALLET_TAR} ewallet.p12
echo "Wallet tar created!"
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
    (ADDRESS = (PROTOCOL = TCP)(HOST = ${B_HOST1_IP})(PORT = ${B_DUP_PORT}))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SID = ${B_SID1})
    )
  )
EOF
echo "TNS alias configured!"
}

check_connectivity(){
# VERIFY CONNECTIVITY BETWEEN PRIMARY AND STANDBY
export tnsping_primresult=$(
tnsping ${A_DBNM}
)
export tnsping_secresult=$(
tnsping ${B_DBNM}
)
export tnsping_duplicate=$(
tnsping DUPLICATE
)

if [[ $tnsping_primresult = *OK* ]]
        then
        echo "Primary database listener reachable on alias"

else
        echo "Primary database cannot be reached using TNS alias. Either connectivty issues or errors in tnsnames"
        echo "Check that the listener is up in primary and that you have the correct config in tnsames"

fi

if [[ $tnsping_secresult = *OK* ]]
        then
        echo "Remote Standby database listener reachable on alias"

else
        echo "Remote Standby database cannot be reached using TNS alias. Either connectivty issues or errors in tnsnames"
        echo "Check that the listener is up in standby and that you have the correct config in tnsames"
fi

if [[ $tnsping_duplicate = *OK* ]]
        then
        echo "Remote listener for duplication reachable on alias"

else
        echo "Remote listener for duplication  cannot be reached using TNS alias. Either connectivty issues or errors in tnsnames"
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

echo "********************************Preparing Primary DB for Data Guard*******************************"
retrieve_dbservice
echo "Retrieving DB SYS passwod..."
retrieve_sys_password
retrieve_sys_password_result=$?
if [ "$retrieve_sys_password_result" == 1 ]
        then
	create_wallet_tar
	configure_tns_alias
	check_connectivity
        echo "********************************Primary Database Prepared for DR*******************************"
else
        echo "Invalid password. Check DB connection and credentials"
fi
