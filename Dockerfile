FROM alpine:latest as UpdatedAlpine
RUN apk update && apk add bash openrc

FROM UpdatedAlpine
RUN apk add wget nfs-utils curl vsftpd tftp-hpa mariadb mariadb-client php7 php7-pcntl php7-posix php7-bcmath php7-sockets php7-zip php7-json php7-curl php7-ldap php7-openssl php7-session php7-mysqli php7-ftp php7-fpm php7-mbstring php7-gd php7-pdo php7-pdo_mysql php7-gettext nginx 
RUN mysql_install_db --user=mysql --datadir=/var/lib/mysqlb
ADD data /preinstall
ADD entry.sh /entry.sh
RUN chmod +x /entry.sh
CMD /entry.sh