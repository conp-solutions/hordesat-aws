################
FROM ubuntu:18.04 AS horde_base
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt install -y openssh-server iproute2 openmpi-bin openmpi-common iputils-ping \
    && mkdir /var/run/sshd \
    && sed 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' -i /etc/pam.d/sshd \
    && setcap CAP_NET_BIND_SERVICE=+eip /usr/sbin/sshd \
    && useradd -ms /bin/bash horde \
    && chown -R horde /etc/ssh/ \
    && su - horde -c \
        'ssh-keygen -q -t rsa -f ~/.ssh/id_rsa -N "" \
        && cp ~/.ssh/id_rsa.pub ~/.ssh/authorized_keys \
        && cp /etc/ssh/sshd_config ~/.ssh/sshd_config \
        && sed -i "s/UsePrivilegeSeparation yes/UsePrivilegeSeparation no/g" ~/.ssh/sshd_config \
        && printf "Host *\n\tStrictHostKeyChecking no\n" >> ~/.ssh/config'
WORKDIR /home/horde
ENV NOTVISIBLE "in users profile"
RUN echo "export VISIBLE=now" >> /etc/profile
EXPOSE 22


################
FROM ubuntu:18.04 AS builder
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt install -y cmake build-essential zlib1g-dev libopenmpi-dev git wget unzip build-essential zlib1g-dev iproute2 cmake python python-pip build-essential gfortran wget curl

# pick a hordesat repository
ARG HORDESAT_REPO=https://github.com/conp-solutions/hordesat
# default value should be: origin/master
ARG HORDESAT_BRANCH=origin/master

RUN mkdir -p /opt/hordesat
# either use the local version
# ADD . /opt/hordesat
# or use a fresh remote clone, where we at least control the repository and commit
RUN git clone $HORDESAT_REPO /opt/hordesat/hordesat
RUN cd /opt/hordesat/hordesat && git remote -v
RUN cd /opt/hordesat/hordesat && git checkout $HORDESAT_BRANCH
RUN cd /opt/hordesat/hordesat && git log --decorate --pretty=oneline --graph | head -n 10
RUN cd /opt/hordesat/hordesat && git submodule update --init --recursive

# build the solver
RUN cd /opt/hordesat/hordesat && make -C hordesat-src


################
FROM horde_base AS horde_liaison
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt install -y awscli python3 mpi

# make hordesat available as /hordesat/hordesat
COPY --from=builder /opt/hordesat/hordesat /hordesat/

# copy scripts from this repository into the home directory of the 'horde' user
ADD make_combined_hostfile.py /home/horde/make_combined_hostfile.py
RUN chmod 755 /home/horde/make_combined_hostfile.py
ADD mpi-run.sh /home/horde/mpi-run.sh
USER horde
CMD ["/usr/sbin/sshd", "-D", "-f", "/home/horde/.ssh/sshd_config"]

RUN ls /home/horde/*
RUN ls /hordesat/*
CMD /home/horde/mpi-run.sh
