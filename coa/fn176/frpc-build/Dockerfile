# Local frpc image: the official frp binary, no registry pull.
#
# Docker Hub pulls on fn176 crawl (~50 kB/s through the registry mirrors), so
# this image is assembled from the release tarball instead.
#
#   v0.71.0 — same version as the frps running on the VPS (soulcore.asia).
#
# build:  bash build-frpc.sh      (builds coa-frpc:local)
FROM alpine:3.20
COPY frpc /usr/local/bin/frpc
RUN chmod +x /usr/local/bin/frpc
ENTRYPOINT ["/usr/local/bin/frpc", "-c", "/etc/frp/frpc.toml"]
