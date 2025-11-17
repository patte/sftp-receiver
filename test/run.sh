#!/usr/bin/env bash

# test suite for sftp-receiver
#
# Security tests:
# - Host key persistence across container restarts
# - Shell access blocked (internal-sftp only)
# - TTY requests denied
# - Port forwarding disabled
# - Chroot restriction (cannot access files outside /home/scanner)
# - Unauthorized SSH keys rejected
# - Wrong usernames rejected (e.g., root)
# - Cannot write outside /upload directory
# - Files are moved (not copied) from upload to consume directory
#
# Functionality tests:
# - SCP file upload
# - SFTP protocol works correctly
# - File integrity verification (byte-for-byte comparison)
# - Automatic file consumption via inotify watcher

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PORT="${PORT:-3022}"
export TEST_SFTP_PORT="$PORT"
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-sftp_test}"
COMPOSE_FILE="test/docker-compose.test.yml"
TMP_DIR="$ROOT_DIR/test/tmp"
KEY_PATH="$TMP_DIR/id_ed25519"
CLIENT_KEYS_DIR="$TMP_DIR/sftp-receiver/client_keys"
CONSUME_DIR="$TMP_DIR/consume"
SSH_USER="scanner@localhost"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=5 -o LogLevel=ERROR)
COMPOSE=(docker compose -f "$COMPOSE_FILE")

log() { printf '>> %s\n' "$*"; }

cleanup() {
  set +e
  "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

prepare_tmp() {
  log "Preparing temporary directories and keys"
  rm -rf "$TMP_DIR"
  mkdir -p "$CLIENT_KEYS_DIR" "$CONSUME_DIR"
  ssh-keygen -q -t ed25519 -N "" -f "$KEY_PATH"
  chmod 600 "$KEY_PATH"
  cp "$KEY_PATH.pub" "$CLIENT_KEYS_DIR/test.pub"
}

wait_for_sshd() {
  for _ in $(seq 1 40); do
    if ssh-keyscan -p "$PORT" localhost >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  log "sshd did not become ready in time"
  exit 1
}

ssh_run() {
  ssh -p "$PORT" -i "$KEY_PATH" "${SSH_OPTS[@]}" "$SSH_USER" "$@"
}

scp_put() {
  local src="$1"
  local dest="$2"
  scp -P "$PORT" -i "$KEY_PATH" "${SSH_OPTS[@]}" "$src" "$SSH_USER:/upload/$dest"
}

wait_for_file() {
  local path="$1"
  for _ in $(seq 1 30); do
    if [[ -f "$path" ]]; then
      return 0
    fi
    sleep 1
  done
  log "Timed out waiting for $path"
  exit 1
}

assert_cmp() {
  local a="$1" b="$2"
  if ! cmp -s "$a" "$b"; then
    log "File contents differ between $a and $b"
    exit 1
  fi
}

get_host_key() {
  ssh-keyscan -p "$PORT" localhost 2>/dev/null | awk 'NR==1 {print $3}'
}

prepare_tmp

log "Building and starting sftp container"
"${COMPOSE[@]}" up -d --build
wait_for_sshd

log "Host key persistence across restart"
KEY1="$(get_host_key)"
"${COMPOSE[@]}" restart sftp >/dev/null
wait_for_sshd
KEY2="$(get_host_key)"
if [[ -z "$KEY1" || "$KEY1" != "$KEY2" ]]; then
  log "Host key mismatch across restart"
  exit 1
fi

log "Shell access is blocked (forced internal-sftp)"
set +e
SSH_OUT="$(ssh_run 'echo ok' 2>&1)"
RC=$?
set -e
if [[ $RC -eq 0 ]]; then
  log "Unexpected ability to run shell commands"
  exit 1
fi
printf '%s\n' "$SSH_OUT" | sed 's/^/SSH_BLOCK: /'

check_no_tty() {
  log "TTY requests are denied"
  set +e
  OUT=$(ssh -tt -p "$PORT" -i "$KEY_PATH" "${SSH_OPTS[@]}" "$SSH_USER" 2>&1 <<<"" )
  RC=$?
  set -e
  printf '%s\n' "$OUT" | sed 's/^/SSH_TTY: /'
  if [[ $RC -eq 0 ]] || ! grep -iq 'PTY allocation request failed' <<<"$OUT"; then
    log "TTY request was not denied as expected"
    exit 1
  fi
}

check_no_tty

log "Port forwarding is denied"
set +e
SSH_FWD_LOG="$(mktemp)"
timeout 2 ssh \
  -p "$PORT" -i "$KEY_PATH" "${SSH_OPTS[@]}" \
  -o ExitOnForwardFailure=yes \
  -N -L 127.0.0.1:9999:127.0.0.1:22 \
  "$SSH_USER" >"$SSH_FWD_LOG" 2>&1
FWD_RC=$?
set -e
FWD_OUT="$(cat "$SSH_FWD_LOG")"
printf '%s\n' "$FWD_OUT" | sed 's/^/SSH_FWD: /'
# The connection should fail (non-zero exit) because forwarding is denied
# Either explicitly with "forwarding" message or implicitly by the forced-command
if [[ $FWD_RC -eq 0 ]]; then
  log "Port forwarding was not properly denied (connection succeeded)"
  exit 1
fi
# Additionally verify that we can't actually use the tunnel
if nc -z 127.0.0.1 9999 2>/dev/null; then
  log "Port forwarding tunnel is active - security violation!"
  exit 1
fi
rm -f "$SSH_FWD_LOG"

log "Chroot restriction: cannot access files outside /upload"
set +e
SFTP_OUT="$(sftp -P "$PORT" -i "$KEY_PATH" "${SSH_OPTS[@]}" "$SSH_USER" <<EOF 2>&1
ls /
ls /etc
ls /home
ls /var
get /etc/passwd /tmp/test-passwd
exit
EOF
)"
RC=$?
set -e
printf '%s\n' "$SFTP_OUT" | sed 's/^/SFTP_CHROOT: /'
# Check that system directories are not accessible
if ! echo "$SFTP_OUT" | grep -q "Can't ls.*\"/etc\""; then
  log "Chroot broken: /etc directory is accessible"
  exit 1
fi
if ! echo "$SFTP_OUT" | grep -q "Can't ls.*\"/home\""; then
  log "Chroot broken: /home directory is accessible"
  exit 1
fi
if ! echo "$SFTP_OUT" | grep -q "Can't ls.*\"/var\""; then
  log "Chroot broken: /var directory is accessible"
  exit 1
fi
# Verify that system files are NOT accessible
if echo "$SFTP_OUT" | grep -qi 'passwd.*100%\|shadow.*100%'; then
  log "Chroot broken: system files can be downloaded"
  exit 1
fi
# The root directory (/) should only show the chroot contents (upload directory)
# Not system directories like etc, var, usr, bin
if echo "$SFTP_OUT" | grep -E 'drwx.*\s+(bin|usr|lib|opt|srv|sys|proc|dev)\s*$'; then
  log "Chroot broken: system directories visible at root"
  exit 1
fi

log "Unauthorized key is rejected"
UNAUTHORIZED_KEY="$TMP_DIR/unauthorized_key"
ssh-keygen -q -t ed25519 -N "" -f "$UNAUTHORIZED_KEY"
chmod 600 "$UNAUTHORIZED_KEY"
set +e
UNAUTH_OUT="$(ssh -p "$PORT" -i "$UNAUTHORIZED_KEY" "${SSH_OPTS[@]}" "$SSH_USER" 'echo ok' 2>&1)"
RC=$?
set -e
printf '%s\n' "$UNAUTH_OUT" | sed 's/^/UNAUTH: /'
if [[ $RC -eq 0 ]]; then
  log "Unauthorized key was incorrectly accepted"
  exit 1
fi
rm -f "$UNAUTHORIZED_KEY" "$UNAUTHORIZED_KEY.pub"

log "Wrong username is rejected"
set +e
WRONG_USER_OUT="$(ssh -p "$PORT" -i "$KEY_PATH" "${SSH_OPTS[@]}" root@localhost 'echo ok' 2>&1)"
RC=$?
set -e
printf '%s\n' "$WRONG_USER_OUT" | sed 's/^/WRONG_USER: /'
if [[ $RC -eq 0 ]]; then
  log "Wrong username was incorrectly accepted"
  exit 1
fi

log "Uploading text fixture via scp"
TEXT_TEST_FILE="$TMP_DIR/test.txt"
echo "This is a test file for SCP upload." > "$TEXT_TEST_FILE"
scp_put "$TEXT_TEST_FILE" scp-test.txt
wait_for_file "$CONSUME_DIR/scp-test.txt"
assert_cmp "$TEXT_TEST_FILE" "$CONSUME_DIR/scp-test.txt"

log "Uploading generated binary via scp"
BIN_TEST_FILE="$TMP_DIR/test.bin"
dd if=/dev/urandom of="$BIN_TEST_FILE" bs=1024 count=1 >/dev/null 2>&1
scp_put "$BIN_TEST_FILE" scp-test.bin
wait_for_file "$CONSUME_DIR/scp-test.bin"
assert_cmp "$BIN_TEST_FILE" "$CONSUME_DIR/scp-test.bin"

log "SFTP protocol works (not just SCP)"
SFTP_TEST_FILE="$TMP_DIR/sftp-test.txt"
echo "This is a test file for SFTP upload." > "$SFTP_TEST_FILE"
sftp -P "$PORT" -i "$KEY_PATH" "${SSH_OPTS[@]}" "$SSH_USER" <<EOF
cd /upload
put $SFTP_TEST_FILE
exit
EOF
wait_for_file "$CONSUME_DIR/sftp-test.txt"
assert_cmp "$SFTP_TEST_FILE" "$CONSUME_DIR/sftp-test.txt"

log "Files are moved (not copied) from upload to consume"
scp_put "$TEXT_TEST_FILE" move-test.txt
wait_for_file "$CONSUME_DIR/move-test.txt"
assert_cmp "$TEXT_TEST_FILE" "$CONSUME_DIR/move-test.txt"
# Verify the file is NOT in the upload directory inside the container
set +e
"${COMPOSE[@]}" exec -T sftp test -f /home/scanner/upload/move-test.txt
FILE_EXISTS=$?
set -e
if [[ $FILE_EXISTS -eq 0 ]]; then
  log "File still exists in upload directory after move - should be moved not copied!"
  exit 1
fi

log "Cannot write outside /upload directory"
set +e
WRITE_OUT="$(sftp -P "$PORT" -i "$KEY_PATH" "${SSH_OPTS[@]}" "$SSH_USER" <<EOF 2>&1
put $SFTP_TEST_FILE /etc/malicious.txt
put $SFTP_TEST_FILE /malicious.txt
exit
EOF
)"
RC=$?
set -e
printf '%s\n' "$WRITE_OUT" | sed 's/^/SFTP_WRITE: /'
# Should fail or be denied
if [[ -f "$CONSUME_DIR/../malicious.txt" ]] || [[ -f "$CONSUME_DIR/malicious.txt" ]] || [[ -f "/etc/malicious.txt" ]]; then
  log "File was written outside /upload - security violation!"
  exit 1
fi
# Verify the file is not present in the container
set +e
"${COMPOSE[@]}" exec -T sftp test -f /etc/malicious.txt
FILE_EXISTS_ETC=$?
"${COMPOSE[@]}" exec -T sftp test -f /malicious.txt
FILE_EXISTS_ROOT=$?
set -e
if [[ $FILE_EXISTS_ETC -eq 0 || $FILE_EXISTS_ROOT -eq 0 ]]; then
  log "File was written outside /upload - security violation!"
  exit 1
fi

log "All checks passed for sftp-receiver ✔"
