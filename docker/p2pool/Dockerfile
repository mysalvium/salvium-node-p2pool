FROM ubuntu:22.04
ARG DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl jq \
      libuv1 libzmq5 libsodium23 \
      libcurl4 libgssapi-krb5-2; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    groupadd -g 1000 p2pool; \
    useradd -m -u 1000 -g 1000 -s /bin/bash p2pool; \
    mkdir -p /home/p2pool/.p2pool /home/p2pool/stats; \
    chown -R 1000:1000 /home/p2pool

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh

USER 1000:1000
WORKDIR /home/p2pool/.p2pool
EXPOSE 3333 38888 38889
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
