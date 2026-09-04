ARG UBUNTU_IMAGE=ubuntu:22.04@sha256:2edbbc5dc405e9612ba3584ce95480277e3eb374407b5505fe26f17df77c7dbc
FROM ${UBUNTU_IMAGE}
ARG DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl jq unzip; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    groupadd -g 1000 salvium; \
    useradd -m -u 1000 -g 1000 -s /bin/bash salvium; \
    mkdir -p /home/salvium/.salvium /home/salvium/bin; \
    chown -R 1000:1000 /home/salvium

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh

USER 1000:1000
WORKDIR /home/salvium
EXPOSE 19080 19081 19083 19089
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
