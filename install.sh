echo "Centos 7 LEMP install script"
echo "Please answer the following questions."
echo "Please enter main domain name"
read DOMAIN
echo "Please enter home dir, e.g /var/www/domain"
read HOMEDIR
echo $DOMAIN
echo $HOMEDIR
## Install repo's
rpm -Uvh https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
rpm -Uvh  http://rpms.famillecollet.com/enterprise/remi-release-7.rpm

## Clean repo's and update system
yum clean all
yum -y update
yum -y groupinstall "Development Tools"
yum -y install \
openssl-devel \
libxml2-devel \
libxslt-devel \
gd-devel \
perl-ExtUtils-Embed \
GeoIP-devel \
rpmdevtools \
nano \
htop \
perl-core \
firewalld \
policycoreutils \
policycoreutils-python \
letsencrypt \
redis \
tokyocabinet-devel \
ncurses-devel \
bzip2-devel

## Define Version's
OPENSSL="openssl-1.1.0c"
NGINX_VERSION="1.11.7-1"
NJS_VERSION="1.11.7.0.1.6-1"
NGHTTP2_VERSION=""
CURL_VERSION=""
GOACCESS_VERSION=""

rpm -ivh http://nginx.org/packages/mainline/centos/7/SRPMS/nginx-$NGINX_VERSION.el7.ngx.src.rpm
rpm -ivh http://nginx.org/packages/mainline/centos/7/SRPMS/nginx-module-geoip-$NGINX_VERSION.el7.ngx.src.rpm
rpm -ivh http://nginx.org/packages/mainline/centos/7/SRPMS/nginx-module-image-filter-$NGINX_VERSION.el7.ngx.src.rpm
rpm -ivh http://nginx.org/packages/mainline/centos/7/SRPMS/nginx-module-njs-$NJS_VERSION.el7.ngx.src.rpm
rpm -ivh http://nginx.org/packages/mainline/centos/7/SRPMS/nginx-module-perl-$NGINX_VERSION.el7.ngx.src.rpm
rpm -ivh http://nginx.org/packages/mainline/centos/7/SRPMS/nginx-module-xslt-$NGINX_VERSION.el7.ngx.src.rpm

sed -i "/Source12: .*/a Source100: https://www.openssl.org/source/$OPENSSL.tar.gz" /root/rpmbuild/SPECS/nginx.spec
sed -i "s|--with-http_ssl_module|--with-http_ssl_module --with-openssl=$OPENSSL|g" /root/rpmbuild/SPECS/nginx.spec
sed -i '/%setup -q/a tar zxf %{SOURCE100}' /root/rpmbuild/SPECS/nginx.spec
sed -i '/.*Requires: openssl.*/d' /root/rpmbuild/SPECS/nginx.spec

spectool -g -R /root/rpmbuild/SPECS/nginx.spec

rpmbuild -ba /root/rpmbuild/SPECS/nginx.spec
rpmbuild -ba /root/rpmbuild/SPECS/nginx-module-geoip.spec
rpmbuild -ba /root/rpmbuild/SPECS/nginx-module-image-filter.spec
rpmbuild -ba /root/rpmbuild/SPECS/nginx-module-njs.spec
rpmbuild -ba /root/rpmbuild/SPECS/nginx-module-perl.spec
rpmbuild -ba /root/rpmbuild/SPECS/nginx-module-xslt.spec

rpm -Uvh /root/rpmbuild/RPMS/x86_64/nginx-$NGINX_VERSION.el7.centos.ngx.x86_64.rpm

mkdir sources
cd sources

## Install and update SSL
wget https://www.openssl.org/source/$OPENSSL.tar.gz
tar zxf $OPENSSL.tar.gz
cd $OPENSSL
./Configure linux-x86_64 shared no-ssl2 no-ssl3 no-comp enable-ec_nistp_64_gcc_128 -Wl,--enable-new-dtags,-rpath,'$(LIBRPATH)'
make -j 4
make install

export CFLAGS="-I/usr/local/include/ -L/usr/local/lib64 -Wl,-rpath,/usr/local/lib64 -lssl -lcrypto"
export CXXFLAGS="-I/usr/local/include/ -L/usr/local/lib64 -Wl,-rpath,/usr/local/lib64 -lssl -lcrypto"

## enable httpd in selinux
sed -i -e 's/SELINUX=disabled/SELINUX=enforcing/' /etc/selinux/config
semanage permissive -a httpd_t

## Start nginx
systemctl enable nginx
systemctl start nginx

systemctl enable firewalld
systemctl start firewalld
firewall-cmd --permanent --zone=public --add-service=http
firewall-cmd --permanent --zone=public --add-service=https
firewall-cmd --reload

## install nghttp2
cd ..
wget https://github.com/nghttp2/nghttp2/releases/download/v1.17.0/nghttp2-1.17.0.tar.gz
tar zxf nghttp2-1.17.0.tar.gz
cd nghttp2-1.17.0.tar.gz
autoreconf -i --force
automake
autoconf 
./configure 
make 
make install

## Update Curl
cd ..
wget https://curl.haxx.se/download/curl-7.51.0.tar.gz
tar xzf curl-7.51.0.tar.gz
cd curl-7.51.0
./configure --with-ssl=/usr/local --with-nghttp2=/usr/local
make -j 4
make install

openssl dhparam -out /etc/ssl/certs/dhparam.pem 2048

# fix redis background saves on low memory
sysctl vm.overcommit_memory=1 && cat <<SYSCTL_MEM > /etc/sysctl.d/88-vm.overcommit_memory.conf
vm.overcommit_memory = 1
SYSCTL_MEM
 
# increase max connections
sysctl -w net.core.somaxconn=65535 && cat <<SYSCTL_CONN > /etc/sysctl.d/88-net.core.somaxconn.conf
net.core.somaxconn = 65535
SYSCTL_CONN
 
sysctl -w fs.file-max=100000 && cat <<SYSCTL_FILEMAX > /etc/sysctl.d/88-fs.file-max.conf
fs.file-max = 100000
SYSCTL_FILEMAX
 
sed -i "s|^tcp-backlog [[:digit:]]\+|tcp-backlog 65535|" /etc/redis.conf
 
# enable redis service on reboot
systemctl enable redis

# start service
(systemctl status redis > /dev/null && systemctl restart redis) || systemctl start redis

# Create Service to disable THP
cat <<INITD_THP > /etc/init.d/disable-transparent-hugepages
#!/bin/bash
### BEGIN INIT INFO
# Provides:          disable-transparent-hugepages
# Required-Start:    \$local_fs
# Required-Stop:
# X-Start-Before:    mongod mongodb-mms-automation-agent
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Disable Linux transparent huge pages
# Description:       Disable Linux transparent huge pages, to improve
#                    database performance.
### END INIT INFO
 
case \$1 in
  start)
    if [ -d /sys/kernel/mm/transparent_hugepage ]; then
      thp_path=/sys/kernel/mm/transparent_hugepage
    elif [ -d /sys/kernel/mm/redhat_transparent_hugepage ]; then
      thp_path=/sys/kernel/mm/redhat_transparent_hugepage
    else
      return 0
    fi
 
    echo 'never' > \${thp_path}/enabled
    echo 'never' > \${thp_path}/defrag
 
    re='^[0-1]+\$'
    if [[ \$(cat \${thp_path}/khugepaged/defrag) =~ \$re ]]
    then
      # RHEL 7
      echo 0  > \${thp_path}/khugepaged/defrag
    else
      # RHEL 6
      echo 'no' > \${thp_path}/khugepaged/defrag
    fi
 
    unset re
    unset thp_path
    ;;
esac
INITD_THP


chmod 755 /etc/init.d/disable-transparent-hugepages
chkconfig --add disable-transparent-hugepages
 
# Configure Tuned, CentOS 7
mkdir /etc/tuned/no-thp
cat <<TUNED_THP > /etc/tuned/no-thp/tuned.conf
[main]
include=virtual-guest
 
[vm]
transparent_hugepages=never
TUNED_THP
tuned-adm profile no-thp

yum install -y --enablerepo=remi-php70 php php-apcu php-fpm php-opcache php-gd php-mbstring php-mcrypt php-pdo php-xml php-mysqlnd php-imap php-pecl-apcu-bc php-pecl-igbinary php-pecl-redis
systemctl enable php-fpm

mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.bak

cd ../../conf

cp default_temp.conf /etc/nginx/conf.d/default.conf

sed -i -e 's/testdomain/'"$DOMAIN"'/g' /etc/nginx/conf.d/default.conf
sed -i -e 's|testdir|'"$HOMEDIR"'|g' /etc/nginx/conf.d/default.conf

mkdir $HOMEDIR

export DOMAINS="$DOMAIN,www.$DOMAIN"
letsencrypt certonly -a webroot --webroot-path=$HOMEDIR -d $DOMAINS

# test your configuration and reload
nginx -t && systemctl start nginx

#############
##
##  Add Lets encrypt renew script see
## https://news.ycombinator.com/item?id=11705731
##
#############

sed -i -e 's/cgi.fix_pathinfo=1/cgi.fix_pathinfo=0/' /etc/php.ini
sed -i -e 's/user = apache/user = nginx/' /etc/php-fpm.d/www.conf
sed -i -e 's/group = apache/group = nginx/' /etc/php-fpm.d/www.conf
sed -i -e 's/;listen.mode = 0660/listen.mode = 0666/' /etc/php-fpm.d/www.conf
chown -R nginx.nginx /var/log/php-fpm
mkdir -p /var/lib/php/session && mkdir -p /var/lib/php/wsdlcache && mkdir -p /var/lib/php/opcache
chown -R nginx.nginx /var/lib/php/*
mkdir /etc/nginx/cache

rm -f /etc/nginx/conf.d/default.conf
cp default.conf /etc/nginx/conf.d/default.conf

sed -i -e 's/testdomain/'"$DOMAIN"'/g' /etc/nginx/conf.d/default.conf
sed -i -e 's|testdir|'"$HOMEDIR"'|g' /etc/nginx/conf.d/default.conf

## install mariadb 10.0

cat <<MARIA_REPO > /etc/yum.repos.d/mariadb.repo
## MariaDB 10.0 CentOS repository list - created 2016-12-04 20:46 UTC
## http://downloads.mariadb.org/mariadb/repositories/
[mariadb]
name = MariaDB
baseurl = http://yum.mariadb.org/10.0/centos7-amd64
gpgkey=https://yum.mariadb.org/RPM-GPG-KEY-MariaDB
gpgcheck=1
enable=1
MARIA_REPO

yum install -y MariaDB-server MariaDB-client

systemctl enable mysql
systemctl start mysql
mysql_secure_installation

wget http://tar.goaccess.io/goaccess-1.1.1.tar.gz
tar -xzvf goaccess-1.1.1.tar.gz
cd goaccess-1.1.1/

./configure --enable-geoip --enable-utf8 --enable-tcb=btree --with-openssl=/usr/local/ssl/
make
make install

sed -i -e 's|#time-format %f|time-format %T|g' /usr/local/etc/goaccess.conf
sed -i -e 's|#date-format %d/%b/%Y|date-format %d/%b/%Y|g' /usr/local/etc/goaccess.conf
echo 'log-format %h %^[%d:%t %^] "%r" %s %b "%R" "%u"' >> /usr/local/etc/goaccess.conf

#goaccess -f /var/log/nginx/access.log -a > report.html






 
#30 2 * * 1 /usr/bin/letsencrypt renew >> /var/log/le-renew.log
#35 2 * * 1 /bin/systemctl reload nginx
