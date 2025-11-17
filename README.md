# sftp-receiver

Small container to receive files via sftp and have a listener move them to a separate directory out of reach of the sftp user.

Used to receive files from a scanner that only supports sftp, with only ssh-rsa keys and aes128-ctr cipher.

Features:
- [x] small docker image based on `debian:13-slim`
- [x] openssh-server with `internal-sftp` subsystem
- [x] chrooted sftp user `scanner`, only write access to `/upload`
- [x] locked down sshd config (hardening, only user scanner allowed)
- [x] Enabled old cipher `aes128-ctr`, old key algorithm `ssh-rsa`.
- [x] inotifywait watcher to move files from `/home/scanner/upload` to `/data/consume`
- [x] on startup:
  - host keys are generated if none are found in `/var/sftp-receiver/ssh`
  - a client key pair is generated if no public key is found in `/var/sftp-receiver/client_keys`
- [x] GitHub Action to build and push the image to ghcr.io (weekly)
- [x] Test harness using docker compose in `test/`

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

### Tests

The repo includes a Docker-based harness that exercises the SSH hardening, key persistence, and upload watcher end-to-end:

```bash
./test/run.sh
```


## Usage

### Docker
Example docker run:
```bash
docker run -d \
  --name sftp-receiver \
  -p 2222:22 \
  -v /path/to/sftp-receiver-data:/var/sftp-receiver \
  -v /path/to/consume:/data/consume \
  ghcr.io/patte/sftp-receiver:main
```

### Quadlet
Example podman quadlet:
```ini
[Container]
Image=ghcr.io/patte/sftp-receiver:main
AutoUpdate=registry
Volume=/data/sftp-receiver:/var/sftp-receiver
Volume=/data/paperless/consume:/data/consume
Network=internal.network
PublishPort=2222:22
PublishPort=[::]:2222:22
IP=10.99.0.11
IP6=fd10:99::11

[Service]
Restart=on-failure
ExecStartPre=/bin/bash -c "[ -d /data/sftp-receiver ] || mkdir /data/sftp-receiver"
ExecStartPre=ufw allow 2222/tcp
ExecStartPre=ufw route allow proto tcp from any to 10.99.0.11 port 22
ExecStartPre=ufw route allow proto tcp from any to fd10:99::11 port 22
ExecStopPost=ufw delete allow 2222/tcp
ExecStopPost=ufw route delete allow proto tcp from any to 10.99.0.11 port 22
ExecStopPost=ufw route delete allow proto tcp from any to fd10:99::11 port 22

[Install]
WantedBy=multi-user.target
```