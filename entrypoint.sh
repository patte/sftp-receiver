#!/bin/bash

set -e

mkdir -p /run/sshd

KEY_DIR="/var/sftp-receiver/ssh"
CLIENT_KEY_DIR="/var/sftp-receiver/client_keys"
UPLOAD_DIR="/home/scanner/upload"

mkdir -p "$KEY_DIR" "$CLIENT_KEY_DIR"

# Generate SSH host keys if they don’t exist
[[ -f "$KEY_DIR/ssh_host_rsa_key" ]]     || ssh-keygen -q -t rsa -b 4096 -f "$KEY_DIR/ssh_host_rsa_key" -N ""
[[ -f "$KEY_DIR/ssh_host_ecdsa_key" ]]   || ssh-keygen -q -t ecdsa -b 256 -f "$KEY_DIR/ssh_host_ecdsa_key" -N ""
[[ -f "$KEY_DIR/ssh_host_ed25519_key" ]] || ssh-keygen -q -t ed25519 -f "$KEY_DIR/ssh_host_ed25519_key" -N ""

ln -sf "$KEY_DIR/ssh_host_rsa_key"         /etc/ssh/ssh_host_rsa_key
ln -sf "$KEY_DIR/ssh_host_rsa_key.pub"     /etc/ssh/ssh_host_rsa_key.pub
ln -sf "$KEY_DIR/ssh_host_ecdsa_key"       /etc/ssh/ssh_host_ecdsa_key
ln -sf "$KEY_DIR/ssh_host_ecdsa_key.pub"   /etc/ssh/ssh_host_ecdsa_key.pub
ln -sf "$KEY_DIR/ssh_host_ed25519_key"     /etc/ssh/ssh_host_ed25519_key
ln -sf "$KEY_DIR/ssh_host_ed25519_key.pub" /etc/ssh/ssh_host_ed25519_key.pub

# Setup scanner user and chroot permissions
id scanner &>/dev/null || useradd -m -d /home/scanner -s /usr/sbin/nologin scanner
passwd -d scanner
mkdir -p "$UPLOAD_DIR"
chown root:root /home/scanner
chmod 755 /home/scanner
chown root:scanner "$UPLOAD_DIR"
chmod 775 "$UPLOAD_DIR"

# Generate client keypair if it doesn't exist
if [[ ! -f "$CLIENT_KEY_DIR/id_ed25519" ]]; then
    ssh-keygen -q -t ed25519 -N "" -f "$CLIENT_KEY_DIR/id_ed25519"
    echo "=== GENERATED NEW CLIENT PRIVATE KEY (id_ed25519) ==="
    echo
    cat "$CLIENT_KEY_DIR/id_ed25519"
    echo
    echo "=== GENERATED NEW CLIENT PUBLIC KEY (id_ed25519.pub) ==="
    cat "$CLIENT_KEY_DIR/id_ed25519.pub"
    echo
fi

# Set authorized_keys for scanner
mkdir -p /home/scanner/.ssh
cp "$CLIENT_KEY_DIR/id_ed25519.pub" /home/scanner/.ssh/authorized_keys
chown -R scanner:scanner /home/scanner/.ssh
chmod 700 /home/scanner/.ssh
chmod 600 /home/scanner/.ssh/authorized_keys

# Start SSH
echo "Starting sshd..."
/usr/sbin/sshd 
# echo "Starting sshd in debug mode..."
# /usr/sbin/sshd -D -e -d &

# Start watcher in background and track PID
/usr/local/bin/on_upload.sh &
WATCHER_PID=$!

term_handler(){
    echo "Caught signal, shutting down..."
    kill $WATCHER_PID
    wait $WATCHER_PID
    echo "Shutdown complete."
    exit 0
}

# Gracefully handle termination signals
trap 'term_handler' SIGINT SIGTERM

# Wait for watcher to finish
wait $WATCHER_PID