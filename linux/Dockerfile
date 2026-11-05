# Linux build and test image for replay (private/linux_port_plan.md, Phase 0).
# The Swift image comes from linux/swift-image; linux/docker.sh passes it in as SWIFT_IMAGE.
# The Swift image lacks what the test suite needs: python3 with jsonschema (test_mcp_server.py validates structuredContent), the xattr tools (attr), curl, and zip (a test playlist runs /usr/bin/zip).
ARG SWIFT_IMAGE
FROM ${SWIFT_IMAGE}
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3 python3-jsonschema attr curl ca-certificates zip \
    && rm -rf /var/lib/apt/lists/*
