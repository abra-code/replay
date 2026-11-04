# Linux build and test image for replay (private/linux_port_plan.md, Phase 0).
# The Swift image comes from linux/swift-image; linux/docker.sh passes it in as SWIFT_IMAGE.
# The Swift image lacks what the test suite needs: python3, the xattr tools (attr) and curl.
ARG SWIFT_IMAGE
FROM ${SWIFT_IMAGE}
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3 attr curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
