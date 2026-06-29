# A throwaway "remote server" for integration-testing server-manager.
# Ubuntu + sshd + nginx + php-fpm + a passwordless-sudo deploy user.
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y \
        openssh-server nginx sudo curl ca-certificates \
        php-fpm php-cli git \
    && rm -rf /var/lib/apt/lists/*

# deploy user with NOPASSWD sudo (server-manager runs non-interactively).
RUN useradd -m -s /bin/bash deploy \
    && echo 'deploy ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/deploy \
    && mkdir -p /home/deploy/.ssh && chmod 700 /home/deploy/.ssh \
    && mkdir -p /var/run/sshd

# Authorised key is injected at build time from tests/docker/id_test.pub.
COPY id_test.pub /home/deploy/.ssh/authorized_keys
RUN chown -R deploy:deploy /home/deploy/.ssh && chmod 600 /home/deploy/.ssh/authorized_keys

# A sample static site to adopt/provision.
RUN mkdir -p /var/www/demo && echo '<h1>server-manager demo OK</h1>' > /var/www/demo/index.html \
    && chown -R deploy:deploy /var/www/demo

EXPOSE 22 80
# Start php-fpm (version-agnostic), nginx, then sshd in the foreground.
CMD bash -c 'service php8.1-fpm start 2>/dev/null || service php-fpm start 2>/dev/null || true; \
             service nginx start; \
             /usr/sbin/sshd -D'
