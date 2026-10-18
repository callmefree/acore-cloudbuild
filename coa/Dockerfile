# syntax=docker/dockerfile:1
#
# Conquest of Azeroth (CoA) server image - Linux build.
#
# Sources (all pinned by the workflow):
#   core     Corfirean/azerothcore-wotlk-coa      (coa-bots branch)
#   in-tree  <core>/modules/*                     (35 CoA modules shipped inside the fork)
#   injected Corfirean/mod-coa-playerbots         (CoA Bots / playerbots)
#            Corfirean/mod-coa-content-scaling
#            Corfirean/mod-coa-content-scaling/content-packs/{mod-coa-tbc-content,mod-coa-wotlk-content}
#
# Build context: the core checkout after the workflow placed the modules in modules/,
# plus this directory copied to <context>/coa/.
#
# One image, three roles, selected at runtime:
#   ACORE_COMPONENT=worldserver | authserver | dbimport
#   docker run ... <image> worldserver
#
# Toolchain mirrors the fork's own Linux build (Corfirean/coa-server-build, docker/Dockerfile.linux):
# ubuntu 26.04, clang, static scripts + static modules, RelWithDebInfo.

ARG UBUNTU_IMAGE=ubuntu:26.04@sha256:f144425ff09be612d6d9ad965196e9cdc23dae1f42110a8a11a3e9a8198759f7

# ==============================================================================
# Stage: builder
# ==============================================================================
FROM ${UBUNTU_IMAGE} AS builder

ARG DEBIAN_FRONTEND=noninteractive
ARG BUILD_TYPE=RelWithDebInfo
# Parallel compile jobs (0 = nproc).  Lower it when the builder has little RAM.
ARG JOBS=0
# 1 = strip debug information from the three binaries (much smaller image).
ARG STRIP=1
# Version banner values (the build runs without git on purpose).
ARG CORE_REV_HASH=unknown
ARG CORE_REV_BRANCH=unknown
ARG CORE_REV_DATE=unknown

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential ccache clang cmake ninja-build git ca-certificates zstd \
        libboost-all-dev libssl-dev libreadline-dev zlib1g-dev libbz2-dev liblzma-dev libncurses-dev \
        default-libmysqlclient-dev libmysql++-dev libicu-dev libstdc++-16-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /azerothcore
COPY CMakeLists.txt ./
COPY conf conf
COPY deps deps
COPY src src
COPY modules modules
COPY data data

WORKDIR /azerothcore/build
# Compile only: this layer is the expensive one and is exported by the workflow's
# buildx `cache-to: type=gha,mode=max`, so a retry after a packaging mistake does
# not pay the ~90 minute compile again.  Keep the artefact collection out of it.
RUN --mount=type=cache,id=coa-ccache,target=/ccache,sharing=locked \
    export CCACHE_DIR=/ccache CCACHE_MAXSIZE=3G CCACHE_BASEDIR=/azerothcore CCACHE_COMPILERCHECK=content \
    && ccache --zero-stats \
    && cmake /azerothcore -G Ninja \
        -DCMAKE_INSTALL_PREFIX=/azerothcore/env/dist \
        -DAPPS_BUILD=all -DTOOLS_BUILD=all \
        -DSCRIPTS=static -DMODULES=static \
        -DUSE_COREPCH=0 -DUSE_SCRIPTPCH=0 \
        -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
        -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
        -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
        -DBoost_USE_STATIC_LIBS=ON \
        -DWITHOUT_GIT=1 \
        -Drev_hash="${CORE_REV_HASH}" -Drev_branch="${CORE_REV_BRANCH}" -Drev_date="${CORE_REV_DATE}" \
    && cmake --build . --target worldserver authserver dbimport \
        -j "$([ "${JOBS}" -gt 0 ] && echo "${JOBS}" || nproc)" \
    && ccache --show-stats

# Collect the artefacts.  Ninja writes each executable next to its sources, so the
# binaries are build/src/server/apps/{worldserver,authserver} and build/src/tools/dbimport.
RUN set -eux; \
    for b in src/server/apps/worldserver src/server/apps/authserver src/tools/dbimport; do \
        [ -x "$b" ] || { echo "missing build artefact: $b"; ls -l src/server/apps src/tools 2>/dev/null || true; exit 1; }; \
    done; \
    mkdir -p /out/bin /out/etc/modules /out/sql/data /out/sql/modules; \
    cp src/server/apps/worldserver /out/bin/; \
    cp src/server/apps/authserver /out/bin/; \
    cp src/tools/dbimport /out/bin/; \
    cp "$(find /azerothcore/src -name worldserver.conf.dist | head -1)" /out/etc/; \
    cp "$(find /azerothcore/src -name authserver.conf.dist | head -1)" /out/etc/; \
    cp "$(find /azerothcore/src -name dbimport.conf.dist | head -1)" /out/etc/; \
    find /azerothcore/modules -maxdepth 3 -path '*/conf/*.conf.dist' -exec cp -t /out/etc/modules/ {} +; \
    cp -a /azerothcore/data/. /out/sql/data/; \
    for m in /azerothcore/modules/*/; do n="$(basename "$m")"; \
        if [ -d "$m/data" ]; then mkdir -p "/out/sql/modules/$n"; cp -a "$m/data" "/out/sql/modules/$n/data"; fi; \
    done; \
    if [ "${STRIP}" = "1" ]; then strip --strip-debug /out/bin/*; fi; \
    ls -l /out/bin; du -sh /out

# ==============================================================================
# Stage: runtime  (worldserver + authserver + dbimport in one image)
# ==============================================================================
FROM ${UBUNTU_IMAGE} AS runtime

ARG DEBIAN_FRONTEND=noninteractive
ARG USER_ID=1000
ARG GROUP_ID=1000

# Runtime libraries exactly as the fork's own Linux qualification uses them.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libmysqlclient24 libicu78 libncurses6 libreadline8t64 \
        ca-certificates tzdata adduser \
    && rm -rf /var/lib/apt/lists/* \
    && (userdel --remove ubuntu 2>/dev/null || true) \
    && addgroup --gid "${GROUP_ID}" acore \
    && adduser --disabled-password --gecos '' --uid "${USER_ID}" --gid "${GROUP_ID}" acore

ENV ACORE_COMPONENT=unknown \
    AC_FORCE_CREATE_DB=1 \
    PATH=/azerothcore/env/dist/bin:$PATH

WORKDIR /azerothcore
RUN mkdir -p /azerothcore/env/dist/bin /azerothcore/env/dist/data /azerothcore/env/dist/etc \
             /azerothcore/env/dist/logs /azerothcore/env/dist/temp /azerothcore/env/ref/etc

COPY --from=builder /out/bin/ /azerothcore/env/dist/bin/
COPY --from=builder /out/etc/ /azerothcore/env/ref/etc/
# dbimport resolves the SQL from the compiled-in source directory (/azerothcore).
COPY --from=builder /out/sql/data/ /azerothcore/data/
COPY --from=builder /out/sql/modules/ /azerothcore/modules/
COPY coa/entrypoint.sh /azerothcore/entrypoint.sh

RUN chmod 755 /azerothcore/entrypoint.sh && chown -R acore:acore /azerothcore

USER acore
ENTRYPOINT ["/azerothcore/entrypoint.sh"]
CMD ["worldserver"]

# ==============================================================================
# Stage: binaries  (fallback export: no registry needed)
# ==============================================================================
FROM scratch AS binaries
COPY --from=builder /out/ /
