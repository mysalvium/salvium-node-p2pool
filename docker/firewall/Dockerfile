FROM alpine:3.20

RUN apk add --no-cache iptables

COPY salvium-firewall.sh /usr/local/sbin/salvium-firewall
RUN chmod 0755 /usr/local/sbin/salvium-firewall

ENTRYPOINT ["/usr/local/sbin/salvium-firewall"]
