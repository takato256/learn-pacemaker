FROM docker.io/library/rockylinux:9
RUN dnf -y install dnf-plugins-core && \
    dnf config-manager --set-enabled highavailability && \
    dnf -y install systemd dbus openssh-server openssh-clients sudo \
        pacemaker corosync pcs resource-agents httpd iproute iputils \
        procps-ng openssl vim-minimal && \
    (command -v curl || dnf -y install curl-minimal) && \
    dnf clean all && rm -rf /var/cache/dnf
RUN useradd -m -s /bin/bash lab && \
    mkdir -p /etc/ssh/sshd_config.d && \
    printf '%s\n' 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' \
      'PermitRootLogin no' 'PubkeyAuthentication yes' 'AllowUsers lab' \
      'AllowTcpForwarding no' 'X11Forwarding no' 'PermitTunnel no' \
      > /etc/ssh/sshd_config.d/01-lab.conf && \
    systemctl disable httpd pcsd corosync pacemaker sshd && \
    rm -f /etc/ssh/ssh_host_*key* && \
    truncate -s 0 /etc/machine-id && rm -f /var/lib/dbus/machine-id && \
    ln -s /etc/machine-id /var/lib/dbus/machine-id
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
