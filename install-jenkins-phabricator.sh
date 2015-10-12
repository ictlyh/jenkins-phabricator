#!/bin/bash

# Install Jenkins and Phabricator in RHEL
# CentOS 7 tested, for CentOS 5/6, concern:
# 1: MySQL httpd configuration file, support subdirectory?
# 2: Openssh version requirement of Phabricator

# Before running this script, edit configuration
# files in confdir/ directory and this file
# according to your preference, replace
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
HOSTADDRESS=http://<your server ip>

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
rpm --import https://jenkins-ci.org/redhat/jenkins-ci.org.key

echo "Installing jenkins"
yum -y install jenkins
# You can edit /etc/inid.d/jenkins and /etc/sysconfig/jenkins to configure jenkins, leave default here
service jenkins start
chkconfig jenkins on

if [ $RHEL_MAJOR_VER == 5 ]; then
    EPEL_URL="http://dl.fedoraproject.org/pub/epel/5/x86_64/epel-release-5-4.noarch.rpm"
    PACKAGES="httpd git php53 php53-cli php53-mysql php53-process php53-devel php53-gd gcc wget make pcre-devel mysql-server"
elif [ $RHEL_MAJOR_VER == 6 ]; then
    EPEL_URL="http://dl.fedoraproject.org/pub/epel/6/x86_64/epel-release-6-8.noarch.rpm"
    PACKAGES="httpd git php php-cli php-mysql php-process php-devel php-gd php-pecl-apc php-pecl-json php-mbstring mysql-server"
elif [ $RHEL_MAJOR_VER == 7 ]; then
    EPEL_URL="http://dl.fedoraproject.org/pub/epel/7/x86_64/e/epel-release-7-5.noarch.rpm"
    PACKAGES="httpd git php php-cli php-mysql php-process php-devel php-gd php-pecl-apc php-pecl-json php-mbstring python-pip pcre-devel mariadb-server"
else
    echo "RHEL MAJOR VERSION is $RHEL_MAJOR_VER, not in 5 and 7, exit"
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
PHABRICATOR_ROOT=/var/www/html/phabricator
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

service mariadb start
chkconfig mariadb on
service httpd start
chkconfig httpd on

echo "Download and install phabricator"
if [ ! -d "/var/www/html" ]; then
    mkdir -p /var/www/html
fi
cd /var/www/html/
rm -rf libphutil arcanist phabricator
git clone https://github.com/phacility/libphutil.git
git clone https://github.com/phacility/arcanist.git
git clone https://github.com/phacility/phabricator.git

echo "Phabircator configuration"
cp -f $ROOT/confdir/local.json $PHABRICATOR_ROOT/conf/local/
echo "Create repository directory $PHABRICATOR_ROOT/repo"
if [ ! -d $PHABRICATOR_ROOT/repo ]; then
    mkdir -p $PHABRICATOR_ROOT/repo
fi

echo "Setup MariaDB root password"
mysql_secure_installation
echo "Configure MariaDB for Phabricator"
if [ ! -d "/etc/my.cnf.d" ]; then
    mkdir -p /etc/my.cnf.d
fi
cp -f $ROOT/confdir/mariadb.cnf /etc/my.cnf.d/phabricator.cnf
echo "Load phabricator schema into database"
$PHABRICATOR_ROOT/bin/storage upgrade --force

echo "Configure Apache web server for Phabricator"
if [ ! -d "/etc/httpd/conf.d" ]; then
    mkdir -p /etc/httpd/conf.d
fi
cp -f $ROOT/confdir/httpd.conf /etc/httpd/conf.d/phabricator.conf

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
echo "git ALL=(root) SETENV: NOPASSWD: /usr/libexec/git-core/git-upload-pack, /usr/libexec/git-core/git-receive-pack" >> /etc/sudoers
echo "apache ALL=(root) SETENV: NOPASSWD: /usr/libexec/git-core/git-http-backend" >> /etc/sudoers
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
$PHABRICATOR_ROOT/bin/phd restart

echo "Configure firewall for Phabricator and Jenkins"
firewall-cmd --permanent --add-port=80/tcp
firewall-cmd --permanent --add-port=8080/tcp
service firewalld restart

service httpd restart
service mariadb restart

echo "Install Jenkins and Phabricator finished"
echo "Go to $HOSTADDRESS:8080/manage to configure Jenkins"
echo "Go to $HOSTADDRESS to create an admin account for Phabricator"
echo "Go to $HOSTADDRESS/settings/panel/ssh and upload your public key"
