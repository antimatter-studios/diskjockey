FROM alpine:3.19

RUN apk add --no-cache \
    openssh-server \
    vsftpd \
    apache2 \
    apache2-webdav \
    apache2-utils \
    samba \
    bash

# Create test user (same creds for all services)
RUN adduser -D -s /bin/sh testuser && \
    echo "testuser:testpass" | chpasswd

# Create data directories
RUN mkdir -p /data/sftp /data/ftp /data/webdav /data/smb && \
    chown testuser:testuser /data/sftp /data/ftp /data/webdav /data/smb

# SSH/SFTP config
RUN ssh-keygen -A && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config && \
    echo "PermitRootLogin no" >> /etc/ssh/sshd_config && \
    echo "Subsystem sftp internal-sftp" >> /etc/ssh/sshd_config && \
    echo "Match User testuser" >> /etc/ssh/sshd_config && \
    echo "  ForceCommand internal-sftp" >> /etc/ssh/sshd_config && \
    echo "  AllowTcpForwarding no" >> /etc/ssh/sshd_config

# FTP config
COPY vsftpd.conf /etc/vsftpd/vsftpd.conf

# WebDAV config
COPY webdav.conf /etc/apache2/conf.d/webdav.conf
RUN htpasswd -cb /etc/apache2/webdav.htpasswd testuser testpass && \
    chown apache:apache /data/webdav

# Samba config
COPY smb.conf /etc/samba/smb.conf
RUN echo -e "testpass\ntestpass" | smbpasswd -a -s testuser

# Startup script
COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 22 21 8080 445 21000-21010

CMD ["/start.sh"]
