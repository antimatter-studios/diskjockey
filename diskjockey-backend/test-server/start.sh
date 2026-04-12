#!/bin/bash
echo "Starting DiskJockey test services..."

# Start SFTP (SSH)
/usr/sbin/sshd -D &
echo "SFTP started on port 22"

# Start FTP
vsftpd /etc/vsftpd/vsftpd.conf &
echo "FTP started on port 21"

# Start WebDAV (Apache)
httpd -k start
echo "WebDAV started on port 8080"

# Start Samba
smbd --foreground --no-process-group &
echo "SMB started on port 445"

echo "All services running"
wait
