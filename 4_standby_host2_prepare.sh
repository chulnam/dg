##!/bin/bash
#
# Check that this is running by oracle oracle
if [ "$(whoami)" != "oracle" ]; then
        echo "Script must be run as user: oracle"
        exit -1
fi


# Load custom environment variables
. STANDBY_rac_dg.ini

# Specific variable for this script
export B_SID2=${ORACLE_SID}

check_connectivity(){
# VERIFY CONNECTIVITY BETWEEN PRIMARY AND STANDBY
export tnsping_primresult=$(
tnsping ${A_DBNM}
)
export tnsping_secresult=$(
tnsping ${B_DBNM}
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


configure_tns_alias(){
echo "Configuring TNS alias..."

cp $ORACLE_HOME/network/admin/tnsnames.ora $ORACLE_HOME/network/admin/tnsnames.ora.${dt}
cat > $ORACLE_HOME/network/admin/tnsnames.ora <<EOF
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

EOF

echo "TNS alias configured!"

}

create_init_pfile() {
echo "Creating new pfile pointing to the spfile in ASM..."
cat > $ORACLE_HOME/dbs/init${B_SID2}.ora <<EOF
spfile='${B_FILE_LOC_BASE}/${B_DBNM}/PARAMETERFILE/spfile${B_DBNM}.ora'
EOF
 
}


echo "********************************Preparing Secondary host2 for RAC Data Guard*******************************"
configure_tns_alias
check_connectivity
create_init_pfile
echo "********************************Secondary host2 prepared *++++++++++++++++++*******************************"

