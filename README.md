# sftp-receiver

Small container to receive files via sftp and have a listener move them to a separate directory out of reach of the sftp user.

Used to receive files from a scanner that only supports sftp, with only ssh-rsa keys and aes128-ctr cipher.

Features:
- [x] small docker image based on `debian:13-slim`
- [x] openssh-server with `internal-sftp` subsystem
- [x] chrooted sftp user `scanner`, only write access to `/upload`
- [x] locked down sshd config (no password auth, no root login, no port forwarding, no x11 forwarding, only user scanner allowed)
- [x] Enabled old cipher `aes128-ctr`, old key algorithm `ssh-rsa`.
- [x] inotifywait watcher to move files from `/home/scanner/upload` to `/data/consume`
- [x] on startup:
  - host keys are generated if none are found in `/var/sftp-receiver/ssh`
  - a client key pair is generated if no public key is found in `/var/sftp-receiver/client_keys`
- [x] GitHub Action to build (daily) and push the image to ghcr.io

Docker image:
```
ghcr.io/patte/sftp-receiver
```

## Development

```bash
docker compose build && docker compose down && docker compose up
```

```bash
scp -P 2222 -i sftp-receiver/client_keys/id_ed25519 ./test.txt scanner@localhost:/upload/
```