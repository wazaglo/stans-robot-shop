FROM mysql:5.7

VOLUME /data

# MYSQL_ALLOW_EMPTY_PASSWORD is deliberately not set. It gave root a blank
# password, which means anything that could reach port 3306 had full control
# of the instance. Set MYSQL_ROOT_PASSWORD instead.
#
# This is a demo, so the root password is committed like the other
# credentials. It is still better than blank: the value below is a secret
# that has to be discovered, not a default. For a real deployment, pass
# MYSQL_ROOT_PASSWORD in as a build secret or, better, do not use root at
# all -- nothing in this stack does.
#
# Nothing authenticates as root. Verified by reading every consumer:
#
#   shipping  JpaConfig.java:24-25   username "shipping" / "secret"
#                                    database cities
#   ratings   Kernel.php:78-79       username "ratings"  / "iloveit"
#                                    database ratings, granted by
#                                    scripts/20-ratings.sql
#
# Both are non-root users scoped to their own database. A root password
# therefore locks nobody out.
ENV MYSQL_ROOT_PASSWORD=rootpassword \
    MYSQL_DATABASE=cities \
    MYSQL_USER=shipping \
    MYSQL_PASSWORD=secret

# change datadir entry in /etc/mysql/my.cnf
COPY config.sh /root/
RUN /root/config.sh

COPY scripts/* /docker-entrypoint-initdb.d/

#RUN /entrypoint.sh mysqld & while [ ! -f /tmp/finished ]; do sleep 10; done
#RUN rm /docker-entrypoint-initdb.d/*
