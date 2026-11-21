# syntax=docker/dockerfile:1.7
# Minimal static PHP CLI + OpenSSH client + BusyBox (FROM scratch).
# Experiment: curl+iconv only; OpenSSH is ed25519-only (no OpenSSL).

ARG ALPINE_VERSION=3.22

# ---------------------------------------------------------------------------
# Pinned third-party versions / checksums (override via --build-arg)
# ---------------------------------------------------------------------------
ARG CURL_VERSION=8.23.0
ARG CURL_SHA256=8dadd7d2536a314f982ad05a651b713f426bf7d02cc2c76cffb9796f2218e6c5
ARG OPENSSH_VERSION=10.3p1
ARG OPENSSH_SHA256=56682a36bb92dcf4b4f016fd8ec8e74059b79a8de25c15d670d731e7d18e45f4
ARG BUSYBOX_VERSION=1.37.0
ARG BUSYBOX_SHA256=3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4
# Alpine v3.22 main mbedtls (LTS 3.6.x). On mbedTLS 4+, also link -ltfpsacrypto.
ARG MBEDTLS_PKGVER=3.6.8-r0

ARG PHP_VERSION=8.6.0

# Shared size/link flags for our own builds (not Alpine packages).
ARG CFLAGS_COMMON="-Os -ffunction-sections -fdata-sections -fno-pie -fno-asynchronous-unwind-tables -fno-unwind-tables"
ARG LDFLAGS_COMMON="-static -no-pie -Wl,--gc-sections"

# =============================================================================
FROM alpine:${ALPINE_VERSION} AS busybox-builder
ARG BUSYBOX_VERSION
ARG BUSYBOX_SHA256
ARG CFLAGS_COMMON
ARG LDFLAGS_COMMON

RUN apk add --no-cache \
      build-base linux-headers perl

WORKDIR /src
RUN wget -q "https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2" \
 && echo "${BUSYBOX_SHA256}  busybox-${BUSYBOX_VERSION}.tar.bz2" | sha256sum -c - \
 && tar xf "busybox-${BUSYBOX_VERSION}.tar.bz2" \
 && mv "busybox-${BUSYBOX_VERSION}" busybox

WORKDIR /src/busybox
COPY busybox.config .config
RUN yes '' | make oldconfig \
 && make -j"$(nproc)" \
      EXTRA_CFLAGS="${CFLAGS_COMMON}" \
      EXTRA_LDFLAGS="${LDFLAGS_COMMON}" \
 && rm -rf /busybox-root \
 && make CONFIG_PREFIX=/busybox-root install \
 && strip --strip-all /busybox-root/bin/busybox \
 && test -x /busybox-root/bin/busybox \
 && test -L /busybox-root/bin/bash \
 && /busybox-root/bin/busybox echo ok

# =============================================================================
FROM alpine:${ALPINE_VERSION} AS openssh-builder
ARG OPENSSH_VERSION
ARG OPENSSH_SHA256
ARG CFLAGS_COMMON
ARG LDFLAGS_COMMON

RUN apk add --no-cache \
      build-base linux-headers autoconf automake

WORKDIR /src
RUN wget -q "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-${OPENSSH_VERSION}.tar.gz" \
 && echo "${OPENSSH_SHA256}  openssh-${OPENSSH_VERSION}.tar.gz" | sha256sum -c - \
 && tar xf "openssh-${OPENSSH_VERSION}.tar.gz"

WORKDIR /src/openssh-${OPENSSH_VERSION}
# Ed25519 / curve25519 only: built-in crypto, no OpenSSL/zlib/PAM/libedit/FIDO/PKCS11.
# LTO is OK for OpenSSH (unlike PHP/Zend).
ENV CFLAGS="${CFLAGS_COMMON} -flto" \
    LDFLAGS="${LDFLAGS_COMMON} -flto"
RUN ./configure \
      --prefix=/usr \
      --sysconfdir=/etc/ssh \
      --with-privsep-path=/var/empty \
      --with-privsep-user=sshd \
      --without-openssl \
      --without-zlib \
      --without-pam \
      --without-libedit \
      --disable-security-key \
      --disable-pkcs11 \
      --without-pie \
      --without-hardening \
      --disable-etc-default-login \
      --disable-lastlog \
      --disable-utmp \
      --disable-utmpx \
      --disable-wtmp \
      --disable-wtmpx \
      --disable-strip \
 && make -j"$(nproc)" \
 && strip --strip-all ssh ssh-agent ssh-add ssh-keyscan \
 && mkdir -p /out/usr/bin \
 && cp -a ssh ssh-agent ssh-add ssh-keyscan /out/usr/bin/ \
 && ./ssh -V

# =============================================================================
FROM alpine:${ALPINE_VERSION} AS curl-builder
ARG CURL_VERSION
ARG CURL_SHA256
ARG MBEDTLS_PKGVER
ARG CFLAGS_COMMON
ARG LDFLAGS_COMMON

# Pin mbedTLS from Alpine (static libs + headers). APKINDEX checksums are
# arch-specific; pinning package version against alpine:${ALPINE_VERSION} is
# the reproducibility lever used here.
# linux-headers: curl/mbedTLS builds are fine without it on amd64; keep for
# consistency with other compile stages (kernel UAPI on aarch64).
RUN apk add --no-cache \
      build-base linux-headers autoconf automake libtool pkgconf wget \
      "mbedtls-dev=${MBEDTLS_PKGVER}" \
      "mbedtls-static=${MBEDTLS_PKGVER}"

WORKDIR /src
RUN wget -q "https://curl.se/download/curl-${CURL_VERSION}.tar.xz" \
 && echo "${CURL_SHA256}  curl-${CURL_VERSION}.tar.xz" | sha256sum -c - \
 && tar xf "curl-${CURL_VERSION}.tar.xz"

WORKDIR /src/curl-${CURL_VERSION}
# HTTP/HTTPS only; TLS via mbedTLS; no brotli/zstd/nghttp2/idn2/psl/ares/ldap/other protocols.
# LTO OK for curl.
ENV CFLAGS="${CFLAGS_COMMON} -flto" \
    LDFLAGS="${LDFLAGS_COMMON} -flto" \
    PKG_CONFIG="pkg-config --static"
RUN ./configure \
      --prefix=/usr/local \
      --disable-shared \
      --enable-static \
      --enable-http \
      --disable-ftp \
      --disable-file \
      --disable-ldap \
      --disable-ldaps \
      --disable-rtsp \
      --disable-proxy \
      --disable-dict \
      --disable-telnet \
      --disable-tftp \
      --disable-pop3 \
      --disable-imap \
      --disable-smb \
      --disable-smtp \
      --disable-gopher \
      --disable-mqtt \
      --disable-manual \
      --disable-docs \
      --disable-ares \
      --without-brotli \
      --without-zstd \
      --without-libidn2 \
      --without-libpsl \
      --without-nghttp2 \
      --without-nghttp3 \
      --without-ngtcp2 \
      --without-libssh2 \
      --without-libssh \
      --without-librtmp \
      --without-zlib \
      --with-mbedtls \
      --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt \
 && make -j"$(nproc)" \
 && make install \
 && (strip --strip-all /usr/local/bin/curl || true) \
 && /usr/local/bin/curl --version

# Export static curl + mbedTLS artifacts for the PHP stage
RUN mkdir -p /curl-root/usr/local /curl-root/usr/lib /curl-root/usr/include \
 && cp -a /usr/local/. /curl-root/usr/local/ \
 && cp -a /usr/lib/libmbed*.a /curl-root/usr/lib/ \
 && (cp -a /usr/lib/libtfpsacrypto.a /curl-root/usr/lib/ || true) \
 && cp -a /usr/include/mbedtls /curl-root/usr/include/ \
 && (test -d /usr/include/psa && cp -a /usr/include/psa /curl-root/usr/include/ || true) \
 && ls -la /curl-root/usr/lib/

# =============================================================================
FROM alpine:${ALPINE_VERSION} AS php-builder
ARG PHP_VERSION
ARG MBEDTLS_PKGVER
ARG CFLAGS_COMMON
ARG LDFLAGS_COMMON

# linux-headers required on aarch64: ext/standard/crc32.c includes <asm/hwcap.h>
# (HWCAP_CRC32). Alpine ships that UAPI header in linux-headers.
RUN apk add --no-cache \
      build-base linux-headers autoconf automake bison re2c pkgconf wget python3 \
      argp-standalone \
      "mbedtls-dev=${MBEDTLS_PKGVER}" \
      "mbedtls-static=${MBEDTLS_PKGVER}"

COPY --from=curl-builder /curl-root/usr/local /usr/local
COPY --from=curl-builder /curl-root/usr/lib/ /usr/lib/
COPY --from=curl-builder /curl-root/usr/include/ /usr/include/

WORKDIR /src
# Verify php.net source sha256 from releases JSON, then download + extract.
ARG PHP_VERSION
COPY scripts/fetch-php-source.sh /tmp/fetch-php-source.sh
RUN chmod +x /tmp/fetch-php-source.sh \
 && /tmp/fetch-php-source.sh "${PHP_VERSION}" /src

WORKDIR /src/php

# mbedTLS libs for static PHP↔curl link (append tfpsacrypto when present on mbedTLS 4+)
RUN MBEDTLS_LIBS="-lmbedtls -lmbedx509 -lmbedcrypto"; \
    if [ -f /usr/lib/libtfpsacrypto.a ]; then MBEDTLS_LIBS="${MBEDTLS_LIBS} -ltfpsacrypto"; fi; \
    printf '%s\n' "$MBEDTLS_LIBS" > /tmp/mbedtls-libs.txt; \
    cat /tmp/mbedtls-libs.txt

ENV CFLAGS="${CFLAGS_COMMON}" \
    CXXFLAGS="${CFLAGS_COMMON}" \
    LDFLAGS="${LDFLAGS_COMMON}" \
    PKG_CONFIG="pkg-config --static"

# --disable-opcache only on 8.3/8.4; 8.5+ cannot disable it.
# LTO is intentionally NOT used for PHP (Zend global register variables).
# Do NOT pass EXTRA_LIBS= on the make command line — that overrides Makefile
# EXTRA_LIBS and drops -lcurl from --with-curl. Append mbedTLS after configure.
RUN set -eux; \
  MBEDTLS_LIBS="$(cat /tmp/mbedtls-libs.txt)"; \
  MAJOR_MINOR="$(echo "${PHP_VERSION}" | cut -d. -f1-2)"; \
  case "${MAJOR_MINOR}" in \
    8.3|8.4) OPCACHE_ARGS="--disable-opcache" ;; \
    *) OPCACHE_ARGS="" ;; \
  esac; \
  # Seed EXTRA_LIBS so configure's curl detection can still append -lcurl, then
  # we also append mbedTLS after configure for static TLS deps.
  export EXTRA_LIBS="${MBEDTLS_LIBS}"; \
  ./configure \
      --prefix=/usr/local \
      --disable-all \
      --enable-cli \
      --disable-cgi \
      --disable-phpdbg \
      --without-pear \
      ${OPCACHE_ARGS} \
      --without-pcre-jit \
      --with-curl=/usr/local \
      --with-iconv \
  ; \
  # Ensure curl + mbedTLS appear in EXTRA_LIBS (append if configure missed any).
  if ! grep -q '^EXTRA_LIBS = .* -lcurl' Makefile; then \
    curl_static="$(/usr/local/bin/curl-config --static-libs)"; \
    sed -i "s|^EXTRA_LIBS =\\(.*\\)|EXTRA_LIBS =\\1 ${curl_static}|" Makefile; \
  fi; \
  for lib in ${MBEDTLS_LIBS}; do \
    if ! grep -q "^EXTRA_LIBS = .*${lib}" Makefile; then \
      sed -i "s|^EXTRA_LIBS =\\(.*\\)|EXTRA_LIBS =\\1 ${lib}|" Makefile; \
    fi; \
  done; \
  grep '^EXTRA_LIBS =' Makefile; \
  make -j"$(nproc)" EXTRA_LDFLAGS_PROGRAM=-all-static; \
  strip --strip-all sapi/cli/php; \
  ./sapi/cli/php -v; \
  ./sapi/cli/php -m; \
  file sapi/cli/php; \
  ls -la sapi/cli/php; \
  mkdir -p /out/usr/local/bin; \
  cp -a sapi/cli/php /out/usr/local/bin/php

# =============================================================================
FROM alpine:${ALPINE_VERSION} AS rootfs
RUN apk add --no-cache ca-certificates \
 && update-ca-certificates

RUN mkdir -p /rootfs/usr/local/bin \
             /rootfs/usr/bin \
             /rootfs/bin \
             /rootfs/etc/ssl/certs \
             /rootfs/etc/ssh \
             /rootfs/root/.ssh \
             /rootfs/tmp \
             /rootfs/var/empty \
 && chmod 1777 /rootfs/tmp \
 && chmod 700 /rootfs/root/.ssh \
 && chmod 755 /rootfs/var/empty \
 && printf 'root:x:0:0:root:/root:/bin/sh\n' > /rootfs/etc/passwd \
 && printf 'root:x:0:\n' > /rootfs/etc/group \
 && cp /etc/ssl/certs/ca-certificates.crt /rootfs/etc/ssl/certs/ca-certificates.crt

COPY --from=busybox-builder /busybox-root/ /rootfs/
COPY --from=openssh-builder /out/usr/bin/ /rootfs/usr/bin/
COPY --from=php-builder /out/usr/local/bin/php /rootfs/usr/local/bin/php

# Ensure /usr/bin/env and a /usr/bin/bash path for Deployer runLocally / CI scripts.
# BusyBox install already provides /bin/sh and /bin/bash via SH_IS_ASH / BASH_IS_ASH.
RUN set -eux; \
  if [ ! -e /rootfs/usr/bin/env ]; then \
    if [ -e /rootfs/bin/env ]; then ln -sf /bin/env /rootfs/usr/bin/env; \
    else ln -sf /bin/busybox /rootfs/usr/bin/env; fi; \
  fi; \
  ln -sf /bin/busybox /rootfs/usr/bin/bash; \
  test -x /rootfs/usr/local/bin/php; \
  test -x /rootfs/usr/bin/ssh; \
  test -x /rootfs/bin/busybox; \
  test -L /rootfs/bin/bash; \
  test -f /rootfs/etc/ssl/certs/ca-certificates.crt; \
  mkdir -p /rootfs/.capsula; \
  { \
    echo "php_bytes=$(wc -c < /rootfs/usr/local/bin/php)"; \
    echo "ssh_bytes=$(wc -c < /rootfs/usr/bin/ssh)"; \
    echo "busybox_bytes=$(wc -c < /rootfs/bin/busybox)"; \
    echo "rootfs_bytes=$(du -sb /rootfs | cut -f1)"; \
  } > /rootfs/.capsula/sizes.env; \
  cat /rootfs/.capsula/sizes.env

# =============================================================================
FROM scratch
COPY --from=rootfs /rootfs/ /
ENV PATH="/usr/local/bin:/usr/bin:/bin" \
    HOME="/root"
WORKDIR /root
CMD ["/usr/local/bin/php", "-v"]
