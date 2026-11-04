# Fedora 44 with only its Swift runtime package (swift-lang-runtime, Swift 6.3.2 as of 2026-11),
# no toolchain. Used by linux/runtime-check.sh. Fedora installs the runtime into /usr/lib64.
FROM fedora:44
RUN dnf install -y swift-lang-runtime && dnf clean all
