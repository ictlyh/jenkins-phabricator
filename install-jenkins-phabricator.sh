#!/bin/bash

# Install Jenkins and Phabricator in RHEL
# CentOS 6 or CentOS 7

# sshd on port 22 must be 6.2 or newer

# Before running this script, edit configuration
# files httpd2.*.conf/, local.json in directory confdir/
# and this file according to your preference, replace
# <value> with your setting

# If any error occurs, fix the issue and re-run the script

# Exit when error occurs
set -e

# Run this script as user root
if [ `whoami` != "root" ]; then
    echo "Run this script as user root"
    exit 1
fi

RHEL_VER_FILE="/etc/redhat-release"
if [ ! -f $RHEL_VER_FILE ]; then
    echo "It looks like you're not running a Red Hat-derived distribution."
    echo "This script is intended to install Phabricator on RHEL-derived"
    echo "distributions such as RHEL, Fedora, CentOS, and Scientific Linux."
    echo "Proceed with caution."
    exit 1
fi
RHEL_REGEX="release ([0-9]+)\."
if [[ $(cat $RHEL_VER_FILE) =~ $RHEL_REGEX ]]; then
    RHEL_MAJOR_VER=${BASH_REMATCH[1]}
else
    echo "Ut oh, we were unable to determine your distribution's major"
    echo "version number. Please make sure you're running 6.0+ before"
    echo "proceeding."
    exit 1
fi

ROOT=$(cd $(dirname $0); pwd)
HOSTADDRESS=http://<your-server>

## Jenkins Section ##
JENKINS_HOME=/home/jenkins
JENKINS_SLAVE_AGENT_PORT=50000
JENKINS_PORT=8080

echo "Add user jenkins"
if id -u jenkins >/dev/null 2>&1; then
    echo "User jenkins already exists"
else
    useradd -r -c "Jenkins user" -d $JENKINS_HOME -m -s /bin/bash jenkins
fi

echo "Add jenkins repository source"
curl -fL http://pkg.jenkins-ci.org/redhat-stable/jenkins.repo -o /etc/yum.repos.d/jenkins.repo
rpm --import http://pkg.jenkins-ci.org/redhat-stable/jenkins-ci.org.key

echo "Installing jenkins"
yum -y install jenkins
# You can edit /etc/inid.d/jenkins and /etc/sysconfig/jenkins to configure jenkins, leave default here
service jenkins start
chkconfig jenkins on

if [ $RHEL_MAJOR_VER == 5 ]; then
    EPEL_URL="http://dl.fedoraproject.org/pub/epel/5/x86_64/epel-release-5-4.noarch.rpm"
    PACKAGES="httpd git php53 php53-cli php53-mysql php53-process php53-devel php53-gd gcc wget make pcre-devel mysql-server"
    DB_SERVICE=mysqld
elif [ $RHEL_MAJOR_VER == 6 ]; then
    EPEL_URL="http://dl.fedoraproject.org/pub/epel/6/x86_64/epel-release-6-8.noarch.rpm"
    PACKAGES="httpd git php php-cli php-mysql php-process php-devel php-gd php-pecl-apc php-pecl-json php-mbstring mysql-server"
    DB_SERVICE=mysqld
elif [ $RHEL_MAJOR_VER == 7 ]; then
    EPEL_URL="http://dl.fedoraproject.org/pub/epel/7/x86_64/e/epel-release-7-5.noarch.rpm"
    PACKAGES="httpd git php php-cli php-mysql php-process php-devel php-gd php-pecl-apc php-pecl-json php-mbstring python-pip pcre-devel mariadb-server"
    DB_SERVICE=mariadb
else
    echo "RHEL MAJOR VERSION is $RHEL_MAJOR_VER, not between in 5 and 7, exit"
    exit 1
fi

set +e
yum repolist | grep -i epel
if [ $? -ne 0 ]; then
    echo "It doesn't look like you have the EPEL repo enabled. We are to add it for you"
    rpm -Uvh $EPEL_URL
fi
set -e

yum makecache && yum -y update

## Phabricator Section ##
WEB_ROOT=/var/www/html
echo "Installing packages: $PACKAGES"
yum -y install $PACKAGES

if [[ $RHEL_MAJOR_VER == 5 ]]; then
    # Now that we've ensured all the devel packages required for pecl/apc are there, let's
    # set up PEAR, and install apc.
    echo "Attempting to install PEAR"
    wget http://pear.php.net/go-pear.phar
    php go-pear.phar && pecl install apc
fi

if [[ $? -ne 0 ]]; then
    echo "The apc install failed. Continuing without APC, performance may be impacted."
fi

service $DB_SERVICE start
chkconfig $DB_SERVICE on
service httpd start
chkconfig httpd on

echo "Download and install phabricator"
if [ ! -d "/var/www/html" ]; then
    mkdir -p /var/www/html
fi

rm -rf $WEB_ROOT/libphutil $WEB_ROOT/arcanist $WEB_ROOT/phabricator
git clone https://github.com/phacility/libphutil.git $WEB_ROOT/libphutil
git clone https://github.com/phacility/arcanist.git $WEB_ROOT/arcanist
git clone https://github.com/phacility/phabricator.git $WEB_ROOT/phabricator

echo "Phabircator configuration"
cp -f $ROOT/confdir/local.json $WEB_ROOT/phabricator/conf/local/
echo "Create repository directory $WEB_ROOT/phabricator/repo"
if [ ! -d $WEB_ROOT/phabricator/repo ]; then
    mkdir -p $WEB_ROOT/phabricator/repo
fi

echo "Setup MySQL root password"
mysql_secure_installation
echo "Configure MySQL for Phabricator"
if [ ! -d "/etc/my.cnf.d" ]; then
    mkdir -p /etc/my.cnf.d
fi
cp -f $ROOT/confdir/mysql.cnf /etc/my.cnf.d/phabricator.cnf
echo "!include /etc/my.cnf.d/phabricator.cnf" >> /etc/my.cnf

echo "Load phabricator schema into database"
$WEB_ROOT/phabricator/bin/storage upgrade --force

echo "Configure Apache web server for Phabricator"
if [ ! -d "/etc/httpd/conf.d" ]; then
    mkdir -p /etc/httpd/conf.d
fi

if [[ $RHEL_MAJOR_VER == 7 ]]; then
    cp -f $ROOT/confdir/httpd2.4.conf /etc/httpd/conf.d/phabricator.conf
else
    cp -f $ROOT/confdir/httpd2.3.conf /etc/httpd/conf.d/phabricator.conf
fi

echo "Configure PHP for Phabricator"
echo extension=apc.so >> /etc/php.ini
sed -i "s/.*post_max_size.*/post_max_size = 32M/g" /etc/php.ini
sed -i "s/.*upload_max_filesize.*/upload_max_filesize = 10M/g" /etc/php.ini
sed -i "s/.*date.timezone.*/date.timezone = UTC/g" /etc/php.ini

echo "Configure Git for Phabricator "
if id -u git >/dev/null 2>&1; then
    echo "User git already exists, delete password"
    sed -i "s/git:.*/git:NP:::::::/g" /etc/shadow
else
    echo "Add user git"
    useradd -r -p NP -c "Git SSH user" -d /home/git -m -s /bin/bash git
fi

echo "Update file /etc/sudoers"
echo "git ALL=(root) SETENV: NOPASSWD: ALL" >> /etc/sudoers
echo "apache ALL=(root) SETENV: NOPASSWD: ALL" >> /etc/sudoers
ln -sf /usr/libexec/git-core/git-http-backend /usr/bin/git-http-backend
sed -i "s/.*requiretty/#Defaults requiretty/g" /etc/sudoers

echo "Configure ssh port for user git"
cp -f $ROOT/confdir/phabricator-ssh-hook.sh /usr/libexec/
chown root:root /usr/libexec/phabricator-ssh-hook.sh
chmod 755 /usr/libexec/phabricator-ssh-hook.sh
cp -f $ROOT/confdir/sshd_config.phabricator /etc/ssh/
service sshd stop
# Use port 222 for normal ssh connection
sed -i "s/.*Port 22/Port 222/g" /etc/ssh/sshd_config
/usr/sbin/sshd -f /etc/ssh/sshd_config
/usr/sbin/sshd -f /etc/ssh/sshd_config.phabricator 
$WEB_ROOT/phabricator/bin/phd restart

echo "Configure iptables and firewall for Phabricator and Jenkins"
if [[ $RHEL_MAJOR_VER == 7 ]]; then
    firewall-cmd --permanent --add-port=80/tcp
    firewall-cmd --permanent --add-port="$JENKINS_PORT"/tcp
    service firewalld restart
else
    iptables -A INPUT -p tcp --dport 80 -j ACCEPT
    iptables -A INPUT -p tcp --dport $JENKINS_PORT -j ACCEPT
    /etc/rc.d/init.d/iptables save
    service iptables restart
fi
service httpd restart
service $DB_SERVICE restart

echo "Install Jenkins and Phabricator finished"
echo "Go to $HOSTADDRESS:$JENKINS_PORT/manage to configure Jenkins"
echo "Go to $HOSTADDRESS to create an admin account for Phabricator"
echo "Go to $HOSTADDRESS/settings/panel/ssh and upload your public key"
