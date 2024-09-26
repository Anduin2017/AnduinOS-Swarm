FROM ubuntu:22.04
WORKDIR /
RUN apt update
RUN apt install -y apt-mirror git unzip wget cron

# Install a patched version of apt-mirror
RUN wget https://gist.aiursoft.cn/anduin/57a393ed8ed343c9bc8a9ae7a30f61e5/raw/HEAD/apt-mirror -O ./apt-mirror
RUN cp ./apt-mirror /usr/bin/apt-mirror
RUN chown root:root /usr/bin/apt-mirror
RUN chmod 755 /usr/bin/apt-mirror

# Set the configuration file for apt-mirror
RUN mkdir -p /etc/apt
RUN echo "set base_path /var/spool/apt-mirror" > /etc/apt/mirror.list
RUN echo "set nthreads 20" >> /etc/apt/mirror.list
RUN echo "set _tilde 0" >> /etc/apt/mirror.list

RUN echo "deb http://archive.ubuntu.com/ubuntu/ jammy main restricted universe multiverse" >> /etc/apt/mirror.list
RUN echo "deb http://archive.ubuntu.com/ubuntu/ jammy-updates main restricted universe multiverse" >> /etc/apt/mirror.list
RUN echo "deb http://archive.ubuntu.com/ubuntu/ jammy-backports main restricted universe multiverse" >> /etc/apt/mirror.list
RUN echo "deb http://archive.ubuntu.com/ubuntu/ jammy-security main restricted universe multiverse" >> /etc/apt/mirror.list

RUN echo "deb [arch=i386] http://archive.ubuntu.com/ubuntu/ jammy main restricted universe multiverse" >> /etc/apt/mirror.list
RUN echo "deb [arch=i386] http://archive.ubuntu.com/ubuntu/ jammy-updates main restricted universe multiverse" >> /etc/apt/mirror.list
RUN echo "deb [arch=i386] http://archive.ubuntu.com/ubuntu/ jammy-backports main restricted universe multiverse" >> /etc/apt/mirror.list
RUN echo "deb [arch=i386] http://archive.ubuntu.com/ubuntu/ jammy-security main restricted universe multiverse" >> /etc/apt/mirror.list

RUN echo "clean http://archive.ubuntu.com/ubuntu/" >> /etc/apt/mirror.list

VOLUME /var/spool/apt-mirror

# Register a crontab job to run apt-mirror every day
RUN crontab -l | { cat; echo "0 5 * * * /usr/bin/apt-mirror"; } | crontab -

# Run this job at the beginning with verbose output
ENTRYPOINT ["cron", "-f", "-L 15"]
