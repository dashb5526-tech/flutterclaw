# iOS Sandbox image — Alpine 3.21 riscv64 with pre-installed tools.
#
# This image is converted to a TinyEMU RISC-V Wasm module via container2wasm.
# Network access is provided at runtime by gvisor-tap-vsock (virtual subnet
# 192.168.127.0/24, gateway at .1, guest at .3). DNS resolves via the gateway.
#
# To rebuild the Wasm artefact:
#   cd scripts/ios-sandbox && ./build.sh
FROM riscv64/alpine:3.21

# Configure DNS to use the gvisor-tap-vsock gateway as resolver.
RUN echo "nameserver 192.168.127.1" > /etc/resolv.conf

# Pre-install tools needed by the agent.
# Additional packages can be installed at runtime via `apk add`.
RUN apk add --no-cache \
    python3 \
    py3-pip \
    git \
    curl \
    wget \
    jq \
    bash \
    file

# Working directory for the agent.
RUN mkdir -p /root && echo 'export PS1="[\u@ios-sandbox \W]\$ "' >> /root/.bashrc
WORKDIR /root
