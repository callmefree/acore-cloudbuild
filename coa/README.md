# CoA Linux server image — cloud build + fn176 deployment

Docker deployment of **Conquest of Azeroth (CoA)** on fn176, built in GitHub
Actions because fn176 cannot afford a local AzerothCore build (its two
`qemu-system-x86` VMs hold ~20 GB of the 30 GB RAM).

## Why a cloud build

There is **no ready-made CoA Docker image anywhere** (Docker Hub, GHCR): every
published AzerothCore image is the plain upstream core without CoA's custom
classes or modules. The only prebuilt CoA artifacts are Windows binaries in
`Corfirean/coa-server-build` releases. So the image is built from source here.

## What is built

| source | ref input | role |
| --- | --- | --- |
| `Corfirean/azerothcore-wotlk-coa` | `core_ref` (default `coa-bots`) | core + **35 in-tree CoA modules** (`modules/mod-coa-*`, `mod-ascension`, `mod-craftsmans-codex`, …) |
| `Corfirean/mod-coa-playerbots` | `bots_ref` (default `master`) | **CoA Bots** (playerbots) — `module/src` + `module/conf` |
| `Corfirean/mod-coa-content-scaling` | `scaling_ref` (default `main`) | scaling module + `content-packs/mod-coa-{tbc,wotlk}-content` |

Module placement and the toolchain mirror the fork's own Linux release job
(`Corfirean/coa-server-build/.github/workflows/build-linux.yml`): the
`mod-coa-playerbots` module is flattened from `module/{src,conf}`, the content
packs are copied next to the scaling module, the build runs on **ubuntu 26.04**
with clang, static scripts/modules and `RelWithDebInfo`.

One image carries three binaries and is role-selected at runtime with
`ACORE_COMPONENT=worldserver|authserver|dbimport`.

### Deliberate deviations

- **SQUID (`Zyth45/mod-playerbots`) is not built.** The official job builds it
  alongside CoA Bots; the CoA Bots module is the selected bot system, so SQUID
  would only cost build time and a second bot database.
- **`dbimport` is built** (the official job drops it and ships prepared database
  baselines instead). Creating the databases from the pinned SQL guarantees the
  schema matches the exact core revision in the image.
- The build runs **without git** (`-DWITHOUT_GIT=1` + explicit revision build
  args), so `.git` never enters the build context.
- The CoA Bots characters-database tables ship in `mod-coa-playerbots/dist/sql`
  (the Windows installer applies them by hand); the workflow places them on the
  module SQL path so `dbimport` applies them.

## Running it

`.github/workflows/coa-linux-image.yml` → *Run workflow*. It pushes
`ghcr.io/callmefree/coa-server:<tag>` and `:latest`, and also uploads a
`coa-server-bin-<tag>.tar.zst` artifact (binaries + config templates + all SQL)
so a deployment never depends on the registry being reachable.

## Deploying on fn176

`coa/fn176/` holds the deployment: `docker-compose.yml` (mysql 8.4 +
one-shot `dbimport` + authserver + worldserver), `config/dbimport.conf`,
`.env.example` and `deploy.sh`.

```
/vol1/1000/docker/coa-fn176/
  docker-compose.yml   .env        deploy.sh
  config/              worldserver.conf, authserver.conf, dbimport.conf, modules/
  data/                dbc/ maps/ vmaps/ mmaps/ Cameras/   (game data)
```

Game data comes from the fork's own signed Windows install package
(`Corfirean/coa-server-build` release `server-0.261015.58`,
`install-base.tar.zst.001/.002`, sha256
`ca2e374c0127b9c2f9b486025b8067a78d528274564a8d03e90f7d97e88b2ff5` /
`ab373ed52a8187b2897d51c52c082205875aab833259cb0365b1a5fff46655a0`), which is
the only source of game data that matches CoA Custom 1.7 (395 `dbc` files, plus
29 k vmaps / 11.9 k maps / 8.5 k mmaps). The third-party `d3athbl0w/CoA-Docker`
`Data.zip` was built for a different fork and is not used.

`./deploy.sh` pulls the image, seeds and patches `config/`, starts MySQL, runs
`dbimport`, repoints `acore_auth.realmlist` at `192.168.1.176:8085`, and starts
both servers.

Client: WotLK 3.3.5a with `realmlist.wtf` → `set realmlist 192.168.1.176`.
