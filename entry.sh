#!/bin/bash
######## Variables                                                                                                                                                           [  started  ]
Services=$(echo mariadb nginx php-fpm7 in.tftpd rpcbind nginx vsftpd FOGImageReplicator FOGImageSize FOGMulticastManager  FOGPingHosts FOGScheduler FOGSnapinHash FOGSnapinReplicator)
Webdirdest=/var/www/fog
Ipaddress="$(ifconfig | grep -A 1 'eth0' | tail -1 | cut -d ':' -f 2 | cut -d ' ' -f 1)"
Interface="eth0"
username="fogproject"
password="password"
storageLocation="/images"
storageLocationCapture="/images/dev"
tftpdirdst="/var/tftpboot"
[[ -z $MySQLHost ]] && MySQLHost="localhost"
######## Helper Functions

SetupOpenRC()
{
    dots "Setting up OpenRC"
    openrc >> /output/entry.log 2>&1
    mkdir -p /var/run/fog
    touch /run/openrc/softlevel
    sleep 2
    echo "OK"
}

StopService()
{
    service=$1
    dots "Stopping $service"
    if [[ ! -f "/etc/init.d/$service" ]] || [[ ! -z $(rc-service $service status | grep -e stopped) ]]; then
        echo "Already Stopped."
        return
    fi
    rc-service $service stop >> /output/entry.log 2>&1
    sleep 2
    errorStat $?
}
StartService()
{
    service=$1
    dots "Starting $service"
    if [[ ! -z $(rc-service $service status | grep -e started) ]]; then
        echo "Already Started."
        return
    fi
    rc-service ${service} start -v >> /output/entry.log 2>&1
    sleep 3
    errorStat $?
}
StopServices()
{

    for service in $Services;
    do
        StopService $service
    done
}

CreateRandomPassword()
{
    size=$1
    if [[ -n size ]];then
       tr -dc A-Za-z0-9 </dev/urandom | head -c 13 ; echo ''
    else
        tr -dc A-Za-z0-9 </dev/urandom | head -c $size ; echo ''
    fi
}

ClearOutputFolder()
{
    dots "Clearing Outputfolder"
    [[ ! -d /output ]] && mkdir - p /output
    if [[ -z $(ls -A /output) ]]; then
        echo "OK"
        return
    fi
    rm -r /output/*  >> /output/entry.log 2>&1
    errorStat $?
}


dots()
{
    local pad=$(printf "%0.1s" "."{1..60})
    printf " * %s%*.*s" "$1" 0 $((60-${#1})) "$pad"
    return 0
}

errorStat()
{
    local status=$1
    local skipOk=$2
    if [[ $status != 0 ]]; then
        echo "Failed!"
        if [[ -z $exitFail ]]; then
            echo
            echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            echo
            tail -n 5 /output/entry.log
            exit $status
        fi
    fi
    [[ -z $skipOk ]] && echo "OK"
}

SetupMySQL()
{
    StopServices
    dots "Setup MySQL"
    sed -i '/.*skip-networking/ s/^#*/#/' -i /etc/my.cnf.d/mariadb-server.cnf  >> /output/entry.log 2>&1
    cp -r /var/lib/mysqlb/. /var/lib/mysql/
    
    echo "OK"

    StartService mariadb 

    [[ -z $MySQLUser ]] && MySQLUser="fogmaster"
    [[ -z $MySQLUserPassword ]] && MySQLUserPassword=$(CreateRandomPassword)
    [[ -n $MySQLHost ]] && host="--host=$MySQLHost"
    [[ -z $MySQLDatabase ]] && MySQLDatabase="fog"
    MySQLOptionsRoot="${host} --user root"
    MySQLOptionsUser="${host} -s --user ${MySQLUser}"


    IsMySQLAvailable

    dots "Setting up Database and User"
    mysql $MySQLOptionsRoot --execute="quit" >/dev/null 2>&1
    MySQLIsRootUseable=$?
    if [[ MySQLIsRootUseable -eq 0 ]]; then
        mysqlrootauth=$(mysql $MySQLOptionsRoot --database=mysql --execute="SELECT Host,User,plugin FROM user WHERE Host='localhost' AND User='root' AND plugin='unix_socket'")
        if [[ -z $mysqlrootauth ]]; then
            echo
            echo
            echo "Detected a blank \"root\" password, changing it..."
            echo
            MySQLNewRootPassword=$(CreateRandomPassword)
            echo "New Password for Root is $MySQLNewRootPassword"
            echo
            echo
            mysqladmin $MySQLOptionsRoot password "${MySQLNewRootPassword}" >> /output/entry.log 2>&1
        fi
        MySQLFogStoragePassword=$(mysql -s $MySQLOptionsRoot --password="${MySQLNewRootPassword}" --execute="SELECT settingValue FROM globalSettings WHERE settingKey LIKE '%FOG_STORAGENODE_MYSQLPASS%'" $MySQLDatabase 2>/dev/null | tail -1)
    else
        MySQLFogStoragePassword=$(mysql $MySQLOptionsUser --password="${MySQLUserPassword}" --execute="SELECT settingValue FROM globalSettings WHERE settingKey LIKE '%FOG_STORAGENODE_MYSQLPASS%'" $MySQLDatabase 2>/dev/null | tail -1)
    fi
    mysql $MySQLOptionsUser --password="${MySQLUserPassword}" --execute="quit" >/dev/null 2>&1
    connect_as_fogmaster=$?
    mysql ${host} -s --user=fogstorage --password="${MySQLFogStoragePassword}" --execute="quit" >/dev/null 2>&1
    connect_as_fogstorage=$?
    if [[ $connect_as_fogmaster -eq 0 && $connect_as_fogstorage -eq 0 ]]; then
        echo "Skipped"
        return
    fi

    if [[ MySQLIsRootUseable -ne 0 ]]; then
        echo
        echo
        echo "MySQL-Database is messed up or \"root\" password is wrong"
        echo "Please check your Dockervariable MySQLRootPassword"
        echo "Failed"
        echo
        exit 1
    fi

    MySQLFogStoragePassword=$(mysql -s $MySQLOptionsRoot --password="${MySQLNewRootPassword}" --execute="SELECT settingValue FROM globalSettings WHERE settingKey LIKE '%FOG_STORAGENODE_MYSQLPASS%'" $MySQLDatabase 2>/dev/null | tail -1)
    if [[ -z $MySQLFogStoragePassword ]]; then
        MySQLFogStoragePassword=$(CreateRandomPassword)
    fi

    cat >./fog-db-and-user-setup.sql <<EOF
SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='ANSI' ;
DELETE FROM mysql.user WHERE User='' ;
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1') ;
DROP DATABASE IF EXISTS test ;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%' ;
CREATE DATABASE IF NOT EXISTS $MySQLDatabase ;
USE $MySQLDatabase ;
DROP PROCEDURE IF EXISTS $MySQLDatabase.create_user_if_not_exists ;
DELIMITER $$
CREATE PROCEDURE $MySQLDatabase.create_user_if_not_exists()
BEGIN
  DECLARE masteruser BIGINT DEFAULT 0 ;
  DECLARE storageuser BIGINT DEFAULT 0 ;

  SELECT COUNT(*) INTO masteruser FROM mysql.user
    WHERE User = '${MySQLUser}' and  Host = '${MySQLHost}' ;
  IF masteruser > 0 THEN
    DROP USER '${MySQLUser}'@'${MySQLHost}';
  END IF ;
  CREATE USER '${MySQLUser}'@'${MySQLHost}' IDENTIFIED BY '${MySQLUserPassword}' ;
  GRANT ALL PRIVILEGES ON $MySQLDatabase.* TO '${MySQLUser}'@'${MySQLHost}' ;

  SELECT COUNT(*) INTO storageuser FROM mysql.user
    WHERE User = 'fogstorage' and  Host = '%' ;
  IF storageuser > 0 THEN
    DROP USER 'fogstorage'@'%';
  END IF ;
  CREATE USER 'fogstorage'@'%' IDENTIFIED BY '${MySQLFogStoragePassword}' ;
END ;$$
DELIMITER ;
CALL $MySQLDatabase.create_user_if_not_exists() ;
DROP PROCEDURE IF EXISTS $MySQLDatabase.create_user_if_not_exists ;
FLUSH PRIVILEGES ;
SET SQL_MODE=@OLD_SQL_MODE ;
EOF
    mysql $MySQLOptionsRoot --password="${MySQLNewRootPassword}" <./fog-db-and-user-setup.sql  >> /output/entry.log 2>&1
    errorStat $?

}

IsMySQLAvailable()
{
    dots "Checking if MySQL-Server is Available"
    mysqladmin $host ping >/dev/null 2>&1 || mysqladmin $host ping >/dev/null 2>&1 || mysqladmin $host ping >/dev/null 2>&1
    errorStat $?
}

MySQLBackup() {
    dots "Backing up database"
    [[ ! -d /var/lib/mysql/fogDBbackups ]] && mkdir -p /var/lib/mysql/fogDBbackups  >> /output/entry.log 2>&1
    wget -O /var/lib/mysql/fogDBbackups/fog_sql_$(date +"%Y%m%d_%I%M%S").sql "http://$Ipaddress/fog/maintenance/backup_db.php" --post-data="type=sql&fogajaxonly=1"   >> /output/entry.log 2>&1
    if [[ $? -ne 0 ]]; then
        echo "Failed"
    else
        echo "Done"
    fi
}

updateDB() {
    dots "Updating Database"
    local replace='s/[]"\/$&*.^|[]/\\&/g'
    local escstorageLocation=$(echo /images | sed -e $replace)
    sed -i -e "s/'\/images\/'/'$escstorageLocation'/g" /var/www/fog/commons/schema.php
    wget --no-check-certificate -qO - --post-data="confirm&fogverified" --no-proxy http://${Ipaddress}/fog/management/index.php?node=schema >> /output/entry.log 2>&1
    errorStat $?

    dots "Update fogstorage database password"
    mysql $MySQLOptionsUser --password="${MySQLUserPassword}" --execute="INSERT INTO globalSettings (settingKey, settingDesc, settingValue, settingCategory) VALUES ('FOG_STORAGENODE_MYSQLPASS', 'This setting defines the password the storage nodes should use to connect to the fog server.', \"$MySQLFogStoragePassword\", 'FOG Storage Nodes') ON DUPLICATE KEY UPDATE settingValue=\"$MySQLFogStoragePassword\"" $MySQLDatabase >> /output/entry.log 2>&1
    errorStat $?

    dots "Granting access to fogstorage database user"
    mysql ${MySQLHost} -s --user=fogstorage --password="${MySQLFogStoragePassword}" --execute="INSERT INTO $MySQLDatabase.taskLog VALUES ( 0, '999test', 3, '127.0.0.1', NOW(), 'fog');" >/dev/null 2>&1
    connect_as_fogstorage=$?
    if [[ $connect_as_fogstorage -eq 0 ]]; then
        mysql $MySQLOptionsUser --password="${MySQLUserPassword}" --execute="DELETE FROM $MySQLDatabase.taskLog WHERE taskID='999test' AND ip='127.0.0.1';" >/dev/null 2>&1
        echo "Skipped"
        return
    fi

    # we still need to grant access for the fogstorage DB user
    # and therefore need root DB access
    mysql $MySQLOptionsRoot --password="${MySQLNewRootPassword}" --execute="quit" >> /output/entry.log 2>&1
    if [[ $? -ne 0 ]]; then
        echo
        echo "   Failed! Terminating installer now."
        exit 1
    fi
    cat >./fog-db-grant-fogstorage-access.sql <<EOF
SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='ANSI' ;
GRANT SELECT ON $MySQLDatabase.* TO 'fogstorage'@'%' ;
GRANT INSERT,UPDATE ON $MySQLDatabase.hosts TO 'fogstorage'@'%' ;
GRANT INSERT,UPDATE ON $MySQLDatabase.inventory TO 'fogstorage'@'%' ;
GRANT INSERT,UPDATE ON $MySQLDatabase.multicastSessions TO 'fogstorage'@'%' ;
GRANT INSERT,UPDATE ON $MySQLDatabase.multicastSessionsAssoc TO 'fogstorage'@'%' ;
GRANT INSERT,UPDATE ON $MySQLDatabase.nfsGroupMembers TO 'fogstorage'@'%' ;
GRANT INSERT,UPDATE ON $MySQLDatabase.tasks TO 'fogstorage'@'%' ;
GRANT INSERT,UPDATE ON $MySQLDatabase.taskStates TO 'fogstorage'@'%' ;
GRANT INSERT,UPDATE ON $MySQLDatabase.taskLog TO 'fogstorage'@'%' ;
GRANT INSERT,UPDATE ON $MySQLDatabase.snapinTasks TO 'fogstorage'@'%' ;
GRANT INSERT,UPDATE ON $MySQLDatabase.snapinJobs TO 'fogstorage'@'%' ;
GRANT INSERT,UPDATE ON $MySQLDatabase.imagingLog TO 'fogstorage'@'%' ;
FLUSH PRIVILEGES ;
SET SQL_MODE=@OLD_SQL_MODE ;
EOF
    mysql $MySQLOptionsRoot --password="${MySQLNewRootPassword}" <./fog-db-grant-fogstorage-access.sql >> /output/entry.log 2>&1
    errorStat $?
}

######## Nginx

SetupNginx()
{
    StopService nginx
    StopService php-fpm7
    dots "Setting up Nginx"
    [[ ! -z $DEBUGMODE ]] && sed -i 's/display_errors = Off/display_errors = On/' /etc/php7/php.ini  >> /output/entry.log 2>&1
    sed -i 's/post_max_size\ \=\ 8M/post_max_size\ \=\ 3000M/g' /etc/php7/php.ini  >> /output/entry.log 2>&1
    sed -i 's/upload_max_filesize\ \=\ 2M/upload_max_filesize\ \=\ 3000M/g' /etc/php7/php.ini  >> /output/entry.log 2>&1
    sed -i 's/.*max_input_vars\ \=.*$/max_input_vars\ \=\ 250000/g' /etc/php7/php.ini  >> /output/entry.log 2>&1

    for i in $(find /var/www/fog -type f -name "*[A-Z]*\.class\.php" -o -name "*[A-Z]*\.event\.php" -o -name "*[A-Z]*\.hook\.php" >> /output/entry.log 2>&1); do
                mv "$i" "$(echo $i | tr A-Z a-z)"  >> /output/entry.log 2>&1
            done

    cp /preinstall/nginx/default.conf /etc/nginx/http.d/default.conf  >> /output/entry.log 2>&1
    cp -r /preinstall/web/ $Webdirdest  >> /output/entry.log 2>&1
    ln -s /var/www/fog /var/www/fog
    echo "OK"
    CreatingConfigFile
    CreateRedirectionFile
    dots "Changing permissions on apache log files"
    chown -R nginx:nginx $Webdirdest
    errorStat $?
    StartService nginx
    StartService php-fpm7
}

CreatingConfigFile()
{
    dots "Creating config file"
    phpescsnmysqlpass="${MySQLUserPassword//\\/\\\\}";   # Replace every \ with \\ ...
    phpescsnmysqlpass="${phpescsnmysqlpass//\'/\\\'}"   # and then every ' with \' for full PHP escaping
    echo "<?php
/**
 * The main configuration FOG uses.
 *
 * PHP Version 5
 *
 * Constructs the configuration we need to run FOG.
 *
 * @category Config
 * @package  FOGProject
 * @author   Tom Elliott <tommygunsster@gmail.com>
 * @license  http://opensource.org/licenses/gpl-3.0 GPLv3
 * @link     https://fogproject.org
 */
/**
 * The main configuration FOG uses.
 *
 * @category Config
 * @package  FOGProject
 * @author   Tom Elliott <tommygunsster@gmail.com>
 * @license  http://opensource.org/licenses/gpl-3.0 GPLv3
 * @link     https://fogproject.org
 */
class Config
{
    /**
     * Calls the required functions to define items
     *
     * @return void
     */
    public function __construct()
    {
        global \$node;
        self::_dbSettings();
        self::_svcSetting();
        if (\$node == 'schema') {
            self::_initSetting();
        }
    }
    /**
     * Defines the database settings for FOG
     *
     * @return void
     */
    private static function _dbSettings()
    {
        define('DATABASE_TYPE', 'mysql'); // mysql or oracle
        define('DATABASE_HOST', '$MySQLHost');
        define('DATABASE_NAME', '$MySQLDatabase');
        define('DATABASE_USERNAME', '$MySQLUser');
        define('DATABASE_PASSWORD', '$phpescsnmysqlpass');
    }
    /**
     * Defines the service settings
     *
     * @return void
     */
    private static function _svcSetting()
    {
        define('UDPSENDERPATH', '/usr/local/sbin/udp-sender');
        define('MULTICASTINTERFACE', '${Interface}');
        define('UDPSENDER_MAXWAIT', null);
    }
    /**
     * Initial values if fresh install are set here
     * NOTE: These values are only used on initial
     * installation to set the database values.
     * If this is an upgrade, they do not change
     * the values within the Database.
     * Please use FOG Configuration->FOG Settings
     * to change these values after everything is
     * setup.
     *
     * @return void
     */
    private static function _initSetting()
    {
        define('TFTP_HOST', \"${Ipaddress}\");
        define('TFTP_FTP_USERNAME', \"${username}\");
        define(
            'TFTP_FTP_PASSWORD',
            \"${password}\"
        );
        define('TFTP_PXE_KERNEL_DIR', \"${Webdirdest}/service/ipxe/\");
        define('PXE_KERNEL', 'bzImage');
        define('PXE_KERNEL_RAMDISK', 275000);
        define('USE_SLOPPY_NAME_LOOKUPS', true);
        define('MEMTEST_KERNEL', 'memtest.bin');
        define('PXE_IMAGE', 'init.xz');
        define('STORAGE_HOST', \"${Ipaddress}\");
        define('STORAGE_FTP_USERNAME', \"${username}\");
        define(
            'STORAGE_FTP_PASSWORD',
            \"${password}\"
        );
        define('STORAGE_DATADIR', '${storageLocation}/');
        define('STORAGE_DATADIR_CAPTURE', '${storageLocationCapture}');
        define('STORAGE_BANDWIDTHPATH', '/fog/status/bandwidth.php');
        define('STORAGE_INTERFACE', '${Interface}');
        define('CAPTURERESIZEPCT', 5);
        define('WEB_HOST', \"${Ipaddress}\");
        define('WOL_HOST', \"${Ipaddress}\");
        define('WOL_PATH', '/fog/wol/wol.php');
        define('WOL_INTERFACE', \"${Interface}\");
        define('SNAPINDIR', \"/opt/fog/snapins/\");
        define('QUEUESIZE', '10');
        define('CHECKIN_TIMEOUT', 600);
        define('USER_MINPASSLENGTH', 4);
        define('NFS_ETH_MONITOR', \"${Interface}\");
        define('UDPCAST_INTERFACE', \"${Interface}\");
        // Must be an even number! recommended between 49152 to 65535
        define('UDPCAST_STARTINGPORT', 63100);
        define('FOG_MULTICAST_MAX_SESSIONS', 64);
        define('FOG_JPGRAPH_VERSION', '2.3');
        define('FOG_REPORT_DIR', './reports/');
        define('FOG_CAPTUREIGNOREPAGEHIBER', true);
        define('FOG_THEME', 'default/fog.css');
    }
}" > "${Webdirdest}/lib/fog/config.class.php"
    errorStat $?
}

CreateRedirectionFile()
{
    dots "Creating redirection index file"
    if [[ ! -f /var/www/index.php ]]; then
        echo "<?php
header('Location: /fog/index.php');
die();
?>" > /var/www/index.php && chown nginx:nginx /var/www/index.php
        errorStat $?
    else
        echo "Skipped"
    fi
}

######## FOG

configureStorage() {
    dots "Setting up storage"
    [[ ! -d $storageLocation ]] && mkdir $storageLocation >> /output/entry.log 2>&1
    [[ ! -f $storageLocation/.mntcheck ]] && touch $storageLocation/.mntcheck >> /output/entry.log 2>&1
    [[ ! -d $storageLocation/postdownloadscripts ]] && mkdir $storageLocation/postdownloadscripts >> /output/entry.log 2>&1
    if [[ ! -f $storageLocation/postdownloadscripts/fog.postdownload ]]; then
        echo "#!/bin/bash" >"$storageLocation/postdownloadscripts/fog.postdownload"
        echo "## This file serves as a starting point to call your custom postimaging scripts." >>"$storageLocation/postdownloadscripts/fog.postdownload"
        echo "## <SCRIPTNAME> should be changed to the script you're planning to use." >>"$storageLocation/postdownloadscripts/fog.postdownload"
        echo "## Syntax of post download scripts are" >>"$storageLocation/postdownloadscripts/fog.postdownload"
        echo "#. \${postdownpath}<SCRIPTNAME>" >> "$storageLocation/postdownloadscripts/fog.postdownload"
    fi
    [[ ! -d $storageLocationCapture ]] && mkdir $storageLocationCapture >> /output/entry.log 2>&1
    [[ ! -f $storageLocationCapture/.mntcheck ]] && touch $storageLocationCapture/.mntcheck >> /output/entry.log 2>&1
    [[ ! -d $storageLocationCapture/postinitscripts ]] && mkdir $storageLocationCapture/postinitscripts >> /output/entry.log 2>&1
    if [[ ! -f $storageLocationCapture/postinitscripts/fog.postinit ]]; then
        echo "#!/bin/bash" >"$storageLocationCapture/postinitscripts/fog.postinit"
        echo "## This file serves as a starting point to call your custom pre-imaging/post init loading scripts." >>"$storageLocationCapture/postinitscripts/fog.postinit"
        echo "## <SCRIPTNAME> should be changed to the script you're planning to use." >>"$storageLocationCapture/postinitscripts/fog.postinit"
        echo "## Syntax of post init scripts are" >>"$storageLocationCapture/postinitscripts/fog.postinit"
        echo "#. \${postinitpath}<SCRIPTNAME>" >>"$storageLocationCapture/postinitscripts/fog.postinit"
    else
        (head -1 "$storageLocationCapture/postinitscripts/fog.postinit" | grep -q '^#!/bin/bash') || sed -i '1i#!/bin/bash' "$storageLocationCapture/postinitscripts/fog.postinit" >/dev/null 2>&1
    fi
    chmod -R 777 $storageLocation $storageLocationCapture >> /output/entry.log 2>&1
    chown -R $username $storageLocation $storageLocationCapture >> /output/entry.log 2>&1
    errorStat $?
}

ConfigureUsers()
{
    userexists=0
    [[ -z $username || "x$username" = "xfog" ]] && username='fogproject'
    dots "Setting up $username user"
    getent passwd $username > /dev/null
    if [[ $? -eq 0 ]]; then
        if [[ ! -f "$fogprogramdir/.fogsettings" && ! -x /home/$username/warnfogaccount.sh ]]; then
            echo "Already exists"
            echo
            echo "The account \"$username\" already exists but this seems to be a"
            echo "fresh install. We highly recommend to NOT creating this account"
            echo "beforehand as it is supposed to be a system account not meant"
            echo "to be used to login and work on the machine!"
            echo
            echo "Please remove the account \"$username\" manually before running"
            echo "the installer again. Run: userdel $username"
            echo
            exit 1
        else
            lastlog -u $username | tail -n -1 | grep "\*\*.*\*\*" > /dev/null 2>&1
            if [[ $? -eq 1 ]]; then
                echo "Already exists"
                echo
                echo "The account \"$username\" already exists and has been used to"
                echo "logon and work on this machine. We highly recommend you NOT"
                echo "use this account for your work as it is supposed to be a"
                echo "system account!"
                echo
                echo "Please remove the account \"$username\" manually before running"
                echo "the installer again. Run: userdel $username"
                echo
                exit 1
            fi
            echo "Skipped"
        fi
    else
        addgroup -S ${username} >> /output/entry.log 2>&1
        adduser -s "/bin/bash" -S ${username} >> /output/entry.log 2>&1
        addgroup -S ${username} ${username} >> /output/entry.log 2>&1
        errorStat $?
    fi
    dots "Locking $username as a system account"
    touch /home/$username/.bashrc && chown $username:$username /home/$username/.bashrc
    textmessage="You seem to be using the '$username' system account to logon and work \non your FOG server system.\n\nIt's NOT recommended to use this account! Please create a new \naccount for administrative tasks.\n\nIf you re-run the installer it would reset the 'fog' account \npassword and therefore lock you out of the system!\n\nTake care, \nyour FOGproject team"
    grep -q "exit 1" /home/$username/.bashrc || cat >>/home/$username/.bashrc <<EOF

echo -e "$textmessage"
exit 1
EOF
    mkdir -p /home/$username/.config/autostart/
    cat >/home/$username/.config/autostart/warnfogaccount.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Warn users to not use the $username account
Exec=/home/$username/warnfogaccount.sh
Comment=Warn users who use the $username system account to logon
EOF
    chown -R $username:$username /home/$username/.config/
    cat >/home/$username/warnfogaccount.sh <<EOF
#!/bin/bash
title="FOG system account"
text="$textmessage"
z=\$(which zenity)
x=\$(which xmessage)
n=\$(which notify-send)
if [[ -x "\$z" ]]
then
    \$z --error --width=480 --text="\$text" --title="\$title"
elif [[ -x "\$x" ]]
then
    echo -e "\$text" | \$x -center -file -
else
    \$n -u critical "\$title" "\$(echo \$text | sed -e 's/ \\n/ /g')"
fi
EOF
    chmod 755 /home/$username/warnfogaccount.sh
    chown $username:$username /home/$username/warnfogaccount.sh
    errorStat $?
    dots "Setting up $username password"
    if [[ -z $password ]]; then
        [[ -f /var/www/fog/lib/fog/config.class.php ]] && password=$(awk -F '"' -e '/TFTP_FTP_PASSWORD/,/);/{print $2}' /var/www/fog/lib/fog/config.class.php | grep -v "^$")
    fi
    cnt=0
    ret=999
    while [[ $ret -ne 0 && $cnt -lt 10 ]]
    do
        [[ -z $password || $ret -ne 999 ]] && password=$(CreateRandomPassword 20)
        echo -e "$password\n$password" | passwd $username >> /output/entry.log 2>&1
        ret=$?
        let cnt+=1
    done
    errorStat $ret
    echo
    echo
    echo "Password for user fog"
    echo $password
    echo
    echo
    unset cnt
    unset ret
}

configureTFTPandPXE() {
    dots "Copy tftpboot files"
    rm -r /var/tftpboot
    cp -r /preinstall/tftp /var/tftpboot >> /output/entry.log 2>&1
    errorStat $?
    dots "Setting up and starting TFTP and PXE Servers"
    chown -R $username /var/tftpboot >> /output/entry.log 2>&1
    chown -R $username /var/www/fog/service/ipxe >> /output/entry.log 2>&1
    find /var/tftpboot -type d -exec chmod 755 {} \; >> /output/entry.log 2>&1
    find /var/www -type d -exec chmod 755 {} \; >> /output/entry.log 2>&1
    find /var/tftpboot ! -type d -exec chmod 655 {} \; >> /output/entry.log 2>&1
    configureDefaultiPXEfile
    
    errorStat $?
    StartService in.tftpd
}

configureDefaultiPXEfile() {
    [[ -z $webroot ]] && webroot='/fog'
	echo -e "#!ipxe\ncpuid --ext 29 && set arch x86_64 || set arch \${buildarch}\nparams\nparam mac0 \${net0/mac}\nparam arch \${arch}\nparam platform \${platform}\nparam product \${product}\nparam manufacturer \${product}\nparam ipxever \${version}\nparam filename \${filename}\nparam sysuuid \${uuid}\nisset \${net1/mac} && param mac1 \${net1/mac} || goto bootme\nisset \${net2/mac} && param mac2 \${net2/mac} || goto bootme\n:bootme\nchain http://$Ipaddress/fog/service/ipxe/boot.php##params" > "/var/tftpboot/default.ipxe"
}

configureFTP() {
    dots "Setting up and starting VSFTP Server..."
    vsftp=$(vsftpd -version 0>&1 | awk -F'version ' '{print $2}')
    vsvermaj=$(echo $vsftp | awk -F. '{print $1}')
    vsverbug=$(echo $vsftp | awk -F. '{print $3}')
    seccompsand=""
    allow_writeable_chroot=""
    echo -e  "max_per_ip=200\nanonymous_enable=NO\nlocal_enable=YES\nwrite_enable=YES\nlocal_umask=022\ndirmessage_enable=YES\nxferlog_enable=YES\nconnect_from_port_20=YES\nxferlog_std_format=YES\nlisten=YES\npam_service_name=vsftpd\nuserlist_enable=NO\n$seccompsand" > /etc/vsftpd/vsftpd.conf
    
    errorStat $?

    StartService vsftpd
}

configureSnapins() {
    dots "Setting up FOG Snapins"
    mkdir -p /opt/fog/snapins  >> /output/entry.log 2>&1
    if [[ -d /opt/fog/snapins ]]; then
        chmod -R 777 /opt/fog/snapins
        chown -R $username:nginx /opt/fog/snapins
    fi
    errorStat $?
}

installInitScript() {
    dots "Installing FOG System Scripts"
    cp -f /preinstall/init.d/* /etc/init.d/ >> /output/entry.log 2>&1
    errorStat $?
    echo
    echo
    echo " * Configuring FOG System Services"
    echo
    echo
    for i in $(ls -A /etc/init.d/);
    do 
        chmod +x /etc/init.d/$i
    done
}

installFOGServices() {
    dots "Setting up FOG Services"
    mkdir -p /opt/fog/service
    cp -Rf /preinstall/service/* /opt/fog/service/
    chmod +x -R /opt/fog/service/
    mkdir -p /opt/fog/log
    errorStat $?
}

StartFOGServices() {
    echo " * Starting FOG Services....................................."
    for i in $(ls -A /etc/init.d/FOG*)
    do
        StartService $i
    done
}

configureNFS() {
    dots "Setting up exports file"
    echo -e "$storageLocation *(ro,sync,no_wdelay,no_subtree_check,insecure_locks,no_root_squash,insecure,fsid=0)\n$storageLocation/dev *(rw,async,no_wdelay,no_subtree_check,no_root_squash,insecure,fsid=1)" > "/etc/exports"
    echo "OK"
    echo " * Setting up and starting RPCBind"
    StartService rpcbind
    echo " * Setting up and starting NFS Server..."
    StartService nfs
}

registerStorageNode() {
    dots "Checking if this node is registered"
    storageNodeExists=$(wget --no-check-certificate -qO - http://$Ipaddress/fog/maintenance/check_node_exists.php --post-data="ip=${Ipaddress}")
    echo "Done"
    if [[ $storageNodeExists != exists ]]; then
        [[ -z $maxClients ]] && maxClients=10
        dots "Node being registered"
        curl -s -k -X POST -d "newNode" -d "name=$(echo -n $Ipaddress|base64)" -d "path=$(echo -n $storageLocation|base64)" -d "ftppath=$(echo -n $storageLocation|base64)" -d "snapinpath=$(echo -n /opt/fog/snapins/|base64)" -d "sslpath=$(echo -n /|base64)" -d "ip=$(echo -n $Ipaddress|base64)" -d "maxClients=$(echo -n $maxClients|base64)" -d "user=$(echo -n $username|base64)" --data-urlencode "pass=$(echo -n $password|base64)" -d "interface=$(echo -n $Interface|base64)" -d "bandwidth=1" -d "webroot=$(echo -n /var/www/|base64)" -d "fogverified" http://$Ipaddress/fog/maintenance/create_update_node.php
        echo "Done"
    else
        echo " * Node is registered"
    fi
}

updateStorageNodeCredentials() {
    dots "Ensuring node username and passwords match"
    curl -s -k -X POST -d "nodePass" -d "ip=$(echo -n $Ipaddress|base64)" -d "user=$(echo -n $username|base64)" --data-urlencode "pass=$(echo -n $password|base64)" -d "fogverified" http://$Ipaddress/fog/maintenance/create_update_node.php
    echo "Done"
}

RemoveInstallationFiles()
{
    dots "Deleting Installation-files"
    rm -rf /preinstall
    rm *.sql
    errorStat $?
}

PrintLoginData()
{
    echo
    echo " * Setup complete"
    echo
    echo "   You can now login to the FOG Management Portal using"
    echo "   the information listed below.  The login information"
    echo "   is only if this is the first install."
    echo
    echo "   This can be done by opening a web browser and going to:"
    echo
    echo "   http://${Ipaddress}/fog/management"
    echo
    echo "   Default User Information"
    echo "   Username: fog"
    echo "   Password: password"
    echo
}

######## Script

if [[ -d /preinstall ]]; then
ClearOutputFolder
SetupOpenRC
ConfigureUsers
SetupMySQL
SetupNginx
MySQLBackup
updateDB
configureStorage
configureTFTPandPXE
configureFTP
configureSnapins
installInitScript
installFOGServices
StartFOGServices
configureNFS
registerStorageNode
updateStorageNodeCredentials
RemoveInstallationFiles
PrintLoginData
else
rm -r /var/run/*
ClearOutputFolder
SetupOpenRC
touch /run/openrc/softlevel
for i in $Services
do
    StartService $i
done
PrintLoginData
fi
while true;
do
    sleep 1000
done;