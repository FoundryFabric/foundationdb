ARG FDB_VERSION=7.4.6
FROM ghcr.io/foundryfabric/foundationdb-base:${FDB_VERSION}

ARG FDB_VERSION
ARG TARGETARCH

# Add fdbserver + tini on top of the client base
# Use --ignore-scripts to skip post-install maintainer scripts (they run fdbserver directly
# which fails under QEMU emulation during multi-platform builds)
RUN apt-get update && \
    apt-get install -y --no-install-recommends wget tini && \
    FDB_ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "aarch64" || echo "amd64") && \
    wget -qO /tmp/fdb-server.deb \
      "https://github.com/apple/foundationdb/releases/download/${FDB_VERSION}/foundationdb-server_${FDB_VERSION}-1_${FDB_ARCH}.deb" && \
    dpkg --ignore-scripts -i /tmp/fdb-server.deb && \
    rm /tmp/fdb-server.deb && \
    apt-get remove -y wget && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/fdb/data /var/fdb/logs /etc/foundationdb

COPY docker-init.sh /usr/local/bin/fdb-init
RUN chmod +x /usr/local/bin/fdb-init

EXPOSE 4500

ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/fdb-init"]
