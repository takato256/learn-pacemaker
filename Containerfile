FROM docker.io/library/rockylinux:9
RUN dnf -y --enablerepo=highavailability --setopt=install_weak_deps=False install \
      systemd dbus openssh-server sudo pcs pacemaker corosync resource-agents \
      httpd iproute shadow-utils && \
    (command -v curl || dnf -y --setopt=install_weak_deps=False install curl-minimal) && \
    dnf clean all && rm -rf /var/cache/dnf
RUN useradd -m -s /bin/bash lab && \
    mkdir -p /etc/ssh/sshd_config.d && \
    printf '%s\n' 'PasswordAuthentication yes' 'KbdInteractiveAuthentication no' \
      'PermitRootLogin no' 'PubkeyAuthentication no' 'AllowUsers lab' \
      'DisableForwarding yes' > /etc/ssh/sshd_config.d/01-lab.conf && \
    printf '%s\n' 'lab ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/90-lab && \
    chmod 0440 /etc/sudoers.d/90-lab && visudo -cf /etc/sudoers.d/90-lab && \
    systemctl disable httpd pcsd corosync pacemaker sshd && \
    rm -f /etc/ssh/ssh_host_*key* && \
    mkdir -p /var/lib/dbus && truncate -s 0 /etc/machine-id && rm -f /var/lib/dbus/machine-id && \
    ln -s /etc/machine-id /var/lib/dbus/machine-id
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
