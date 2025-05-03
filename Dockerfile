# Multi-stage Dockerfile:
# The `builder` stage compiles the binary and gathers all dependencies in the `/export/` directory.
FROM debian:12 AS builder
RUN apt-get update && apt-get -y upgrade \
 && apt-get -y install wget curl build-essential gcc make libssl-dev pkg-config git jq procps

# Install darkhttpd from Git repo
RUN cd /usr/local/src/ \
 && git clone https://github.com/emikulic/darkhttpd.git \
 && cd darkhttpd \
 && git checkout tags/v1.16 \
 && make \
 && mv darkhttpd /usr/local/bin/

# Install the latest Rust build environment.
RUN curl https://sh.rustup.rs -sSf | bash -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

# Install the `depres` utility for dependency resolution.
RUN cd /usr/local/src/ \
 && git clone https://github.com/rrauch/depres.git \
 && cd depres \
 && git checkout 717d0098751024c1282d42c2ee6973e6b53002dc \
 && cargo build --release \
 && cp target/release/depres /usr/local/bin/

# Install Foundry / Anvil
RUN curl -L https://foundry.paradigm.xyz | bash
ENV PATH="$PATH:/root/.foundry/bin"
RUN foundryup \
 && cp -p /root/.foundry/bin/anvil /usr/local/bin/

RUN cd /usr/local/src/ \
 && git clone https://github.com/maidsafe/autonomi.git \
 && cd autonomi \
 && git checkout stable \
 && cargo build --release --bin antnode \
 && cargo build --release --bin evm-testnet \
 && cargo build --release --bin  antctl \
 && cp -p target/release/antnode /usr/local/bin/ \
 && cp -p target/release/evm-testnet /usr/local/bin/ \
 && cp -p target/release/antctl /usr/local/bin/

RUN groupadd -g 1000 autonomi
RUN useradd -g 1000 -s /bin/sh -d /data autonomi

RUN wget -O /usr/local/sbin/gosu https://github.com/tianon/gosu/releases/download/1.17/gosu-amd64 \
 && chmod 0755 /usr/local/sbin/gosu

COPY run.sh /
RUN chmod 0755 /run.sh

# Use `depres` to identify all required files for the final image.
RUN depres /bin/sh /bin/bash /bin/ls /usr/bin/su /usr/bin/chown \
    /usr/bin/cat /usr/bin/whoami /usr/bin/id /usr/bin/sleep /usr/bin/head \
    /usr/bin/sed /usr/bin/rm /usr/bin/jq /usr/bin/mkdir /usr/bin/pgrep \
    /usr/local/sbin/gosu \
    /usr/local/bin/darkhttpd \
    /usr/local/bin/anvil \
    /usr/local/bin/antnode /usr/local/bin/evm-testnet /usr/local/bin/antctl \
    /run.sh \
    /etc/ssl/certs/ \
    /usr/share/ca-certificates/ \
    >> /tmp/export.list

# Copy all required files into the `/export/` directory.
RUN cat /tmp/export.list \
 # remove all duplicates
 && cat /tmp/export.list | sort -o /tmp/export.list -u - \
 && mkdir -p /export/ \
 && rm -rf /export/* \
 # copying all necessary files
 && cat /tmp/export.list | xargs cp -a --parents -t /export/ \
 && mkdir -p /export/tmp && chmod 0777 /export/tmp

RUN mkdir -p /export/etc/ \
 && cat /etc/passwd | grep autonomi >> /export/etc/passwd \
 && cat /etc/group | grep autonomi >> /export/etc/group


# The final stage creates a minimal image with all necessary files.
FROM scratch
WORKDIR /

# Copy files from the `builder` stage.
COPY --from=builder /export/ /

VOLUME /data
ENV NODE_PORT=53851-53875
EXPOSE 53851-53875/udp

ENV ANVIL_PORT=14143
EXPOSE 14143

ENV BOOTSTRAP_PORT=38112
EXPOSE 38112

ENV REWARDS_ADDRESS=0x728Ce96E4833481eE2d66D5f47B50759EF608c5E

CMD /run.sh
