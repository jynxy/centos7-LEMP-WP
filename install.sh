echo "Centos 7 LEMP install script"
echo "Please answer the following questions."
echo "Please enter main domain name"
read DOMAIN
echo "Please enter home dir, e.g /var/www/domain"
read HOMEDIR
echo $DOMAIN
echo $HOMEDIR
export DOMAINS="$DOMAIN,www.$DOMAIN"
echo $DOMAINS
read -p "Press [Enter] key to start backup..."
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
redis

## Define Version's
OPENSSL="openssl-1.1.0c"
NGINX_VERSION="1.11.7-1"
NJS_VERSION="1.11.7.0.1.6-1"

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
./Configure linux-x86_64 shared no-ssl2 no-ssl3 no-comp enable-ec_nistp_64_gcc_128 -Wl,--enable-new-dtags,-rpath,/usr/local/lib
make -j 4
make install

export CFLAGS="-I/usr/local/include/ -L/usr/local/lib -Wl,-rpath,/usr/local/lib -lssl -lcrypto"
export CXXFLAGS="-I/usr/local/include/ -L/usr/local/lib -Wl,-rpath,/usr/local/lib -lssl -lcrypto"

## enable httpd in selinux
sed -i -e 's/SELINUX=disabled/SELINUX=enforcing/' /etc/selinux/config
semanage permissive -a httpd_t

## Start nginx
systemctl enable nginx
systemctl start nginx

cd ..

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
autoreconf -i
automake
autoconf 
./configure 
make 
make install

## Update Curl
cd..
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

cat <<NGINX_CONF_TEMP > /etc/nginx/conf.d/default.conf
server {
    listen 80;
    listen 443 ssl http2;
    server_name $DOMAIN www.$DOMAIN;
    ssl_protocols TLSv1 TLSv1.1 TLSv1.2;
    ssl_ciphers EECDH+AES128:RSA+AES128:EECDH+AES256:RSA+AES256:EECDH+3DES:RSA+3DES:!MD5;
    ssl_prefer_server_ciphers On;
#    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
#    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
#    ssl_trusted_certificate /etc/letsencrypt/live/$DOMAIN/chain.pem;
    ssl_session_cache shared:SSL:128m;
    add_header Strict-Transport-Security "max-age=31557600; includeSubDomains";
    ssl_stapling on;
    ssl_stapling_verify on;
    # Your favorite resolver may be used instead of the Google one below
    resolver 8.8.8.8;
    root $HOMEDIR;
    index index.html;

    location '/.well-known/acme-challenge' {
        root        $HOMEDIR;
    }

    location / {
        if ($scheme = http) {
            return 301 https://$server_name$request_uri;
        }
    }
}
NGINX_CONF_TEMP

export DOMAINS="$DOMAIN,www.$DOMAIN"
mkdir $HOMEDIR
sudo letsencrypt certonly -a webroot --webroot-path=$HOMEDIR -d $DOMAINS

# test your configuration and reload
nginx -t && systemctl start nginx

touch /etc/crond.weekly/letsencrypt.sh
chmod +x /etc/crond.weekly/letsencrypt.sh

cat <<LE_RENEW > /etc/crond.weekly/letsencrypt.sh
#!/bin/sh
# This script renews all the Let's Encrypt certificates with a validity < 30 days

if ! letsencrypt renew > /var/log/letsencrypt/renew.log 2>&1 ; then
    echo Automated renewal failed:
    cat /var/log/letsencrypt/renew.log
    exit 1
fi
LE_RENEW

/usr/sbin/nginx -t && /usr/sbin/nginx -s reload

sed -i -e 's/cgi.fix_pathinfo=1/cgi.fix_pathinfo=0/' /etc/php.ini
sed -i -e 's/user = apache/user = nginx/' /etc/php-fpm.d/www.conf
sed -i -e 's/group = apache/group = nginx/' /etc/php-fpm.d/www.conf
sed -i -e 's/;listen.mode = 0660/listen.mode = 0666/' /etc/php-fpm.d/www.conf

cat <<NGINX_CONF > /etc/nginx/conf.d/default.conf
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;
    return 301 https://$server_name$request_uri;
}
 
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN www.$DOMAIN;

    ssl_protocols TLSv1 TLSv1.1 TLSv1.2;
    ssl_ciphers EECDH+AES128:RSA+AES128:EECDH+AES256:RSA+AES256:EECDH+3DES:RSA+3DES:!MD5;
    ssl_prefer_server_ciphers On;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/$DOMAIN/chain.pem;
    ssl_session_cache shared:SSL:128m;
    add_header Strict-Transport-Security "max-age=31557600; includeSubDomains";
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;
    ssl_stapling on;
    ssl_stapling_verify on;
    ssl_dhparam /etc/ssl/certs/dhparam.pem;

    # Your favorite resolver may be used instead of the Google one below
    resolver 8.8.8.8 8.8.4.4 valid=300s;
    root $HOMEDIR;
    index index.php index.html;

    location '/.well-known/acme-challenge'
    {
        root $HOMEDIR;
    }

    location /
    {
        if ($scheme = http)
        {
            return 301 https://$server_name$request_uri;
        }
    }

    location ~ .php$ {
       # zero-day exploit defense.
        try_files $uri =404;

        fastcgi_intercept_errors on;
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
    }

    #deny all .ht**** files
    location ~ /\.ht
    {
        deny all;
    }

    # allow CORS for fonts
    location ~* \\.(ttf|ttc|otf|eot|woff2?|font.css|css|svg)\$ {
        add_header Access-Control-Allow-Origin *;
    }

    location ~* (readme|changelog)\\.txt\$ {
        return 444;
    }

    # don't show this as it can leak info
    location ~* /(\\.|(wp-config|xmlrpc)\\.php|(readme|license|changelog)\\.(html|txt)) {
        return 444;
    }

    # no PHP execution in uploads/files
    location ~* /(?:uploads|files)/.*\\.php\$ {
        deny all;
    }

    # hide contents of sensitive files
    location ~* \\.(conf|engine|inc|info|install|make|module|profile|test|po|sh|.*sql|theme|tpl(\\.php)?|xtmpl)\$|^(\\..*|Entries.*|Repository|Root|Tag|Template)\$|\\.php_ {
        return 444;
    }

    # don't allow other executable file types
    location ~* \\.(pl|cgi|py|sh|lua)\$ {
        return 444;
    }
}
NGINX_CONF

chown -R nginx.nginx /var/log/php-fpm
mkdir -p /var/lib/php/session && mkdir -p /var/lib/php/wsdlcache && mkdir -p /var/lib/php/opcache
chown -R nginx.nginx /var/lib/php/*
sed -i -e 's/user = apache/user = nginx/' /etc/php-fpm.d/www.conf
sed -i -e 's/group = apache/group = nginx/' /etc/php-fpm.d/www.conf

## install mariadb 10.0
cat <<REPO > /etc/yum.repos.d/mariadb.repo
## MariaDB 10.0 CentOS repository list - created 2016-12-04 20:46 UTC
## http://downloads.mariadb.org/mariadb/repositories/
[mariadb]
name = MariaDB
baseurl = http://yum.mariadb.org/10.0/centos7-amd64
gpgkey=https://yum.mariadb.org/RPM-GPG-KEY-MariaDB
gpgcheck=1
enable=1
REPO


mkdir /usr/share/nginx/cache












 
#30 2 * * 1 /usr/bin/letsencrypt renew >> /var/log/le-renew.log
#35 2 * * 1 /bin/systemctl reload nginx
