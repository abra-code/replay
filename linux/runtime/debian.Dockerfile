# Debian 13 with only its Swift runtime package (libswiftlang, Swift 6.0.3 as of 2026-11),
# no toolchain. Used by linux/runtime-check.sh; the oldest runtime replay supports.
FROM debian:trixie
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libswiftlang \
    && rm -rf /var/lib/apt/lists/*
