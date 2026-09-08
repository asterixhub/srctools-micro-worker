# syntax=docker/dockerfile:1
FROM debian:bookworm-slim AS builder

ARG ZIG_VERSION=0.16.0
ARG ZIG_SHA256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /zig
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" -o zig.tar.xz \
    && echo "${ZIG_SHA256}  zig.tar.xz" | sha256sum -c - \
    && tar -xf zig.tar.xz --strip-components=1 \
    && rm zig.tar.xz
ENV PATH="/zig:${PATH}"

WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src
RUN zig build -Dtarget=x86_64-linux-musl --release=small \
    && cp zig-out/bin/s /s

FROM scratch
# TLS CA store for std.http.Client; scratch has none.
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=builder /s /s
ENV RAILWAY_VOLUME_MOUNT_PATH=/data
ENTRYPOINT ["/s"]
