FROM ubuntu:24.04@sha256:786a8b558f7be160c6c8c4a54f9a57274f3b4fb1491cf65146521ae77ff1dc54

LABEL org.opencontainers.image.title="ryk CI"
LABEL org.opencontainers.image.description="ryk CLI and runtime resources for CI (shell_engine in-process). orca is a compat alias."
LABEL org.opencontainers.image.source="https://github.com/christopherkarani/Orca"

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates git bash coreutils \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 ryk

# Release automation must verify the archive checksum and extract the complete Linux release root,
# then provide that directory in the Docker build context as ./ryk (or ./orca legacy layout).
COPY ryk /opt/ryk
ENV PATH="/opt/ryk/bin:${PATH}"
ENV ORCA_RESOURCE_ROOT="/opt/ryk"
RUN test -x /opt/ryk/bin/ryk \
    && (test -x /opt/ryk/bin/orca || ln -s ryk /opt/ryk/bin/orca) \
    && test ! -e /opt/ryk/bin/orca-daemon \
    && test -d /opt/ryk/policies \
    && test -d /opt/ryk/schemas \
    && /opt/ryk/bin/ryk version

USER ryk
WORKDIR /home/ryk
ENTRYPOINT ["ryk"]
CMD ["--help"]
