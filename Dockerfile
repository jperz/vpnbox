FROM ubuntu:24.04

LABEL maintainer="Jakob Perz <j.perz@rechenkraft.at>"

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Europe/Vienna

RUN apt update \
  && apt upgrade -qq -y \
  && apt install -qq -y sudo nano jq iptables nftables iputils-ping iputils-tracepath iproute2 net-tools dnsutils supervisor openconnect openvpn wireguard dnsmasq squid dante-server openssh-server bird2 lynx curl netcat-traditional python3 \
    strongswan-swanctl charon-systemd libcharon-extra-plugins libcharon-extauth-plugins

RUN mkdir /data \
  && mkdir -p /usr/local/vpnbox/bin \
  && mkdir -p /var/run/bird \
  && chown bird.bird /var/run/bird \
  && mkdir -p /run/sshd \
  && mkdir -p /etc/swanctl/conf.d /etc/swanctl/x509 /etc/swanctl/x509ca /etc/swanctl/private

# SSH tunnel user: no shell, key-only, port-forward / jump-host only
RUN useradd -r -m -d /home/tunnel -s /bin/false -c "SSH Tunnel User" tunnel \
  && echo "tunnel:$(openssl rand -hex 32)" | chpasswd \
  && mkdir -p /home/tunnel/.ssh \
  && chmod 700 /home/tunnel/.ssh \
  && chown -R tunnel:tunnel /home/tunnel

COPY ./configs/ /etc/
COPY ./bin/ /usr/local/vpnbox/bin/
COPY ./web/ /usr/local/vpnbox/web/
RUN chmod +x /usr/local/vpnbox/bin/*.sh

WORKDIR /data

EXPOSE 3100 3128 1080 22 53

CMD ["/usr/local/vpnbox/bin/startup.sh"]
