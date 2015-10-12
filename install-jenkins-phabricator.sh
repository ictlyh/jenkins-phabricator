#!/bin/bash

# Install Jenkins and Phabricator in CentOS 7
# Before running this script, edit configuration
# files in confdir/ directory and this file
# according to your preference, replace
# <value> with your setting

# Run this file as root user
# If any error occurs, fix the issue and re-run the script

# Exit when error occurs
set -e

ROOT=$(cd $(dirname $0); pwd)
HOSTADDRESS=http://<your server ip>

## Jenkins Section ##
JENKINS_HOME=/home/jenkins
JENKINS_SLAVE_AGENT_PORT=50000
JENKINS_PORT=8080

useradd -r -c "Jenkins user" -d $JENKINS_HOME -m -s /bin/bash jenkins
curl -fL http://pkg.jenkins-ci.org/redhat-stable/jenkins.repo -o /etc/yum.repos.d/jenkins.repo
rpm --import https://jenkins-ci.org/redhat/jenkins-ci.org.key
yum -y install jenkins
# You can edit /etc/inid.d/jenkins and /etc/sysconfig/jenkins to configure jenkins, leave default here
service jenkins start
chkconfig jenkins on

## Phabricator Section ##
PHABRICATOR_ROOT=/var/www/html/phabricator

# Update yum repo
rpm -U http://dl.fedoraproject.org/pub/epel/7/x86_64/e/epel-release-7-5.noarch.rpm
yum makecache && yum -y update

# Install utilities
yum -y install      \
    supervisor      \
    gcc             \
    gcc-c++         \
    openssh         \
    python-pip      \
    httpd           \
    git             \
    php             \
    php-cli         \
    php-mysql       \
    php-process     \
    php-devel       \
    php-gd          \
    php-pecl-apc    \
    php-pecl-json   \
    php-pear        \
    php-mbstring    \
    pcre-devel      \
    mariadb         \
    mariadb-server

pecl install -f apc

service mariadb start
chkconfig mariadb on
service httpd start
chkconfig httpd on

# Download and install phabricator
cd /var/www/html/
rm -rf libphutil arcanist phabricator
git clone https://github.com/phacility/libphutil.git
git clone https://github.com/phacility/arcanist.git
git clone https://github.com/phacility/phabricator.git

# Phabircator configuration
cp -f $ROOT/confdir/local.json $PHABRICATOR_ROOT/conf/local/
# Create repository directory
mkdir -p $PHABRICATOR_ROOT/repo
# Setup MariaDB root password
mysql_secure_installation
# Configure MariaDB for Phabricator
cp -f $ROOT/confdir/mariadb.cnf /etc/my.cnf.d/phabricator.cnf
# Load phabricator schema into database
$PHABRICATOR_ROOT/bin/storage upgrade --force

# Configure Apache web server for Phabricator
cp -f $ROOT/confdir/httpd.conf /etc/httpd/conf.d/phabricator.conf

# Configure PHP for Phabricator
echo extension=apc.so >> /etc/php.ini
sed -i 's/.*post_max_size.*/post_max_size = 32M/g' /etc/php.ini
sed -i 's/.*upload_max_filesize.*/upload_max_filesize = 10M/g' /etc/php.ini
sed -i 's/.*date.timezone.*/date.timezone = UTC/g' /etc/php.ini

# Configure Git for Phabricator 
useradd -r -p NP -c "Git SSH user" -d /home/git -m -s /bin/bash git
echo 'git ALL=(root) SETENV: NOPASSWD: /usr/libexec/git-core/git-upload-pack, /usr/libexec/git-core/git-receive-pack' >> /etc/sudoers
echo 'apache ALL=(root) SETENV: NOPASSWD: /usr/libexec/git-core/git-http-backend' >> /etc/sudoers
ln -sf /usr/libexec/git-core/git-http-backend /usr/bin/git-http-backend
sed -i 's/.*requiretty/#Defaults requiretty/g' /etc/sudoers
cp -f $ROOT/confdir/phabricator-ssh-hook.sh /usr/libexec/
chown root:root /usr/libexec/phabricator-ssh-hook.sh
chmod 755 /usr/libexec/phabricator-ssh-hook.sh
cp -f $ROOT/confdir/sshd_config.phabricator /etc/ssh/
service sshd stop
# Use port 222 for normal ssh connection
sed -i 's/.*Port 22/Port 222/g' /etc/ssh/sshd_config
/usr/sbin/sshd -f /etc/ssh/sshd_config
/usr/sbin/sshd -f /etc/ssh/sshd_config.phabricator 
$PHABRICATOR_ROOT/bin/phd restart

# Configure firewall for Phabricator and Jenkins
firewall-cmd --permanent --add-port=80/tcp
firewall-cmd --permanent --add-port=8080/tcp
service firewalld restart

service httpd restart
service mariadb restart

echo 'Install Jenkins and Phabricator finished'
echo 'Go to $HOSTADDRESS:8080/manage to configure Jenkins'
echo 'Go to $HOSTADDRESS to create an admin account for Phabricator'
echo 'Go to $HOSTADDRESS/settings/panel/ssh and upload your public key'
