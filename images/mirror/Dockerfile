FROM ubuntu:24.10
WORKDIR /
RUN apt update
RUN apt install -y apt-mirror git unzip wget cron

# Install a patched version of apt-mirror
RUN wget https://gist.aiursoft.cn/anduin/57a393ed8ed343c9bc8a9ae7a30f61e5/raw/HEAD/apt-mirror -O ./apt-mirror
RUN chown root:root ./apt-mirror && chmod 755 ./apt-mirror
RUN mv ./apt-mirror /usr/bin/apt-mirror
RUN rm -rf ./apt-mirror-master
RUN chown root:root /usr/bin/apt-mirror
RUN chmod 755 /usr/bin/apt-mirror

# Set the configuration file for apt-mirror
RUN mkdir -p /etc/apt
RUN echo "set base_path /var/spool/apt-mirror" > /etc/apt/mirror.list
RUN echo "set nthreads 20" >> /etc/apt/mirror.list
RUN echo "set _tilde 0" >> /etc/apt/mirror.list

RUN echo "deb http://archive.ubuntu.com/ubuntu/ oracular main restricted universe multiverse" >> /etc/apt/mirror.list
RUN echo "deb http://archive.ubuntu.com/ubuntu/ oracular-updates main restricted universe multiverse" >> /etc/apt/mirror.list
RUN echo "deb http://archive.ubuntu.com/ubuntu/ oracular-backports main restricted universe multiverse" >> /etc/apt/mirror.list
RUN echo "deb http://archive.ubuntu.com/ubuntu/ oracular-security main restricted universe multiverse" >> /etc/apt/mirror.list

RUN echo "deb [arch=i386] http://archive.ubuntu.com/ubuntu/ oracular main restricted universe multiverse" >> /etc/apt/mirror.list
RUN echo "deb [arch=i386] http://archive.ubuntu.com/ubuntu/ oracular-updates main restricted universe multiverse" >> /etc/apt/mirror.list
RUN echo "deb [arch=i386] http://archive.ubuntu.com/ubuntu/ oracular-backports main restricted universe multiverse" >> /etc/apt/mirror.list
RUN echo "deb [arch=i386] http://archive.ubuntu.com/ubuntu/ oracular-security main restricted universe multiverse" >> /etc/apt/mirror.list

RUN echo "deb http://archive.ubuntu.com/ubuntu/ noble main restricted universe multiverse" >> /etc/apt/mirror.list
RUN echo "deb http://archive.ubuntu.com/ubuntu/ noble-updates main restricted universe multiverse" >> /etc/apt/mirror.list
RUN echo "deb http://archive.ubuntu.com/ubuntu/ noble-backports main restricted universe multiverse" >> /etc/apt/mirror.list
RUN echo "deb http://archive.ubuntu.com/ubuntu/ noble-security main restricted universe multiverse" >> /etc/apt/mirror.list

RUN echo "deb [arch=i386] http://archive.ubuntu.com/ubuntu/ noble main restricted universe multiverse" >> /etc/apt/mirror.list
RUN echo "deb [arch=i386] http://archive.ubuntu.com/ubuntu/ noble-updates main restricted universe multiverse" >> /etc/apt/mirror.list
RUN echo "deb [arch=i386] http://archive.ubuntu.com/ubuntu/ noble-backports main restricted universe multiverse" >> /etc/apt/mirror.list
RUN echo "deb [arch=i386] http://archive.ubuntu.com/ubuntu/ noble-security main restricted universe multiverse" >> /etc/apt/mirror.list

RUN echo "deb http://archive.ubuntu.com/ubuntu/ jammy main restricted universe multiverse" >> /etc/apt/mirror.list
RUN echo "deb http://archive.ubuntu.com/ubuntu/ jammy-updates main restricted universe multiverse" >> /etc/apt/mirror.list
RUN echo "deb http://archive.ubuntu.com/ubuntu/ jammy-backports main restricted universe multiverse" >> /etc/apt/mirror.list
RUN echo "deb http://archive.ubuntu.com/ubuntu/ jammy-security main restricted universe multiverse" >> /etc/apt/mirror.list

RUN echo "deb [arch=i386] http://archive.ubuntu.com/ubuntu/ jammy main restricted universe multiverse" >> /etc/apt/mirror.list
RUN echo "deb [arch=i386] http://archive.ubuntu.com/ubuntu/ jammy-updates main restricted universe multiverse" >> /etc/apt/mirror.list
RUN echo "deb [arch=i386] http://archive.ubuntu.com/ubuntu/ jammy-backports main restricted universe multiverse" >> /etc/apt/mirror.list
RUN echo "deb [arch=i386] http://archive.ubuntu.com/ubuntu/ jammy-security main restricted universe multiverse" >> /etc/apt/mirror.list

# RUN echo "deb http://archive.ubuntu.com/ubuntu/ focal main restricted universe multiverse" >> /etc/apt/mirror.list
# RUN echo "deb http://archive.ubuntu.com/ubuntu/ focal-updates main restricted universe multiverse" >> /etc/apt/mirror.list
# RUN echo "deb http://archive.ubuntu.com/ubuntu/ focal-backports main restricted universe multiverse" >> /etc/apt/mirror.list
# RUN echo "deb http://archive.ubuntu.com/ubuntu/ focal-security main restricted universe multiverse" >> /etc/apt/mirror.list

RUN echo "deb-amd64 http://ppa.launchpad.net/nextcloud-devs/client/ubuntu oracular main" >> /etc/apt/mirror.list
RUN echo "deb-amd64 http://ppa.launchpad.net/mozillateam/ppa/ubuntu oracular main" >> /etc/apt/mirror.list
RUN echo "deb-i386 http://ppa.launchpad.net/nextcloud-devs/client/ubuntu oracular main" >> /etc/apt/mirror.list
RUN echo "deb-i386 http://ppa.launchpad.net/mozillateam/ppa/ubuntu oracular main" >> /etc/apt/mirror.list

RUN echo "deb-amd64 http://ppa.launchpad.net/nextcloud-devs/client/ubuntu noble main" >> /etc/apt/mirror.list
RUN echo "deb-amd64 http://ppa.launchpad.net/mozillateam/ppa/ubuntu noble main" >> /etc/apt/mirror.list
RUN echo "deb-i386 http://ppa.launchpad.net/nextcloud-devs/client/ubuntu noble main" >> /etc/apt/mirror.list
RUN echo "deb-i386 http://ppa.launchpad.net/mozillateam/ppa/ubuntu noble main" >> /etc/apt/mirror.list

RUN echo "deb-amd64 http://ppa.launchpad.net/nextcloud-devs/client/ubuntu jammy main" >> /etc/apt/mirror.list
RUN echo "deb-amd64 http://ppa.launchpad.net/mozillateam/ppa/ubuntu jammy main" >> /etc/apt/mirror.list
RUN echo "deb-i386 http://ppa.launchpad.net/nextcloud-devs/client/ubuntu jammy main" >> /etc/apt/mirror.list
RUN echo "deb-i386 http://ppa.launchpad.net/mozillateam/ppa/ubuntu jammy main" >> /etc/apt/mirror.list

RUN echo "clean http://archive.ubuntu.com/ubuntu/" >> /etc/apt/mirror.list

RUN touch /var/spool/apt-mirror/var/postmirror.sh && chmod +x /var/spool/apt-mirror/var/postmirror.sh

VOLUME /var/spool/apt-mirror

# Register a crontab job to run apt-mirror every day
RUN crontab -l | { cat; echo "0 5 * * * /usr/bin/apt-mirror"; } | crontab -

# Run this job at the beginning with verbose output
ENTRYPOINT ["cron", "-f", "-L 15"]