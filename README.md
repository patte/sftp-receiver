# sftp receiver

Small container to receive files via sftp and have a listener move them to a separate directory out of reach of the sftp user.

Used to receive files from a scanner that only supports sftp.

## test

```bash
docker compose build && docker compose down && docker compose up
```

```bash
scp -P 2222 -i sftp-receiver/client_keys/id_ed25519 ~/test.txt scanner@localhost:/upload/
```