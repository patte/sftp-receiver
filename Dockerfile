FROM debian:13-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
  openssh-server \
  inotify-tools \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

COPY sshd_config /etc/ssh/sshd_config
COPY on_upload.sh /usr/local/bin/on_upload.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/on_upload.sh /usr/local/bin/entrypoint.sh

CMD ["/usr/local/bin/entrypoint.sh"]