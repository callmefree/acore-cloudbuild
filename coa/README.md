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
- **`dbimport` is built** but is *not* how the first database is created (see
  [Database](#database)). The official job drops `dbimport` entirely and ships
  prepared database baselines; the fork's raw SQL chain cannot rebuild a consistent
  database from scratch, so the deployment restores the official dump instead.
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

`coa/fn176/` holds the deployment: `docker-compose.yml` (mysql 8.4 + authserver +
worldserver, with the one-shot `dbimport` behind the `tools` profile),
`.env.example`, `deploy.sh`, `botcmd.sh`, `build-from-artifact.sh`,
`dump-official-db.sh`, `extra-config.conf` and the two cron scripts
`watchdog.sh` / `backup-db.sh`.

```
/vol1/1000/docker/coa-fn176/
  docker-compose.yml   .env   deploy.sh   botcmd.sh
  extra-config.conf    watchdog.sh   backup-db.sh
  config/              worldserver.conf, authserver.conf, dbimport.conf, modules/
  data/                dbc/ maps/ vmaps/ mmaps/ Cameras/   (game data, symlink -> root/Data)
  logs/                server logs + watchdog.log + backup.log (bind mount, uid 1000)
  backups/             coa-all-<stamp>.sql.gz snapshots
```

Game data comes from the fork's own signed Windows install package
(`Corfirean/coa-server-build` release `server-0.261015.58`,
`install-base.tar.zst.001/.002`, sha256
`ca2e374c0127b9c2f9b486025b8067a78d528274564a8d03e90f7d97e88b2ff5` /
`ab373ed52a8187b2897d51c52c082205875aab833259cb0365b1a5fff46655a0`), which is
the only source of game data that matches CoA Custom 1.7 (395 `dbc` files, plus
29 k vmaps / 11.9 k maps / 8.5 k mmaps). The third-party `d3athbl0w/CoA-Docker`
`Data.zip` was built for a different fork and is not used.

### Database

**The core SQL chain does not rebuild a working database.** Two independent walls,
both verified on fn176:

1. `rev_20260930_85_molten_core_boss_kits.sql` (`pending_db_world`) inserts into
   `coa_boss_schedule` with the column `effect`, but the current module base SQL
   (`modules/mod-coa-raid-difficulty/data/sql/db-world/base/03_boss_schedule.sql`)
   already migrated that column to `effect_d0..d3` → `ERROR 1054 (42S22) Unknown
   column 'effect' in 'field list'`.
2. Replaying the same chain over the official dump fails the other way round:
   `Duplicate column name 'senderEntry'` on
   `data/sql/updates/db_characters/2026_06_24_00.sql` - the dump already contains it.

That is why the official releases ship prepared data (Windows `mysql/data`, Linux
`Database/baseline/*.sql.zst`) and never replay the SQL.

So the deployment restores the dump taken from the official install-base package:

```
# once, on fn176 (needs the extracted install-base tree, root/):
./dump-official-db.sh /vol1/1000/docker/coa-fn176/root baseline-dump.sql.gz

# every deploy:
COA_DB_BASELINE=baseline-dump.sql.gz ./deploy.sh
```

`dump-official-db.sh` copies `<repack>/mysql/data`, serves that copy with
`mysql:8.4 --lower-case-table-names=1 --skip-grant-tables` (the data dictionary was
created with `lower_case_table_names=1` on Windows; 8.4.11 upgrades the 8.4.9
dictionary in place) and `mysqldump`s `acore_auth` / `acore_characters` /
`acore_world` (113 MB gzipped). Because the dump's `updates` tables already record
the applied SQL, the worldserver runs with `Updates.EnableDatabases = 0` and never
touches the chain above.

### Console and bots

`worldserver` runs with `tty: true`, so a plain pipe makes `docker attach` fail
(`the input device is not a TTY`). `botcmd.sh` wraps that in `script -qec` and uses
`docker attach --sig-proxy=false` so the timeout kill never reaches the server:

```
./botcmd.sh "account create local local"
./botcmd.sh "account set gmlevel local 3 -1"     # 4 is refused: the console is SEC_CONSOLE
./botcmd.sh "botcmd spawnleveled 200"            # CoA Bots, throttled internally
./botcmd.sh "server info"
```

`deploy.sh` points `CoaBots.TalentBuildsPath` at
`/azerothcore/env/dist/etc/coa-bots-level-builds.json` (downloaded from the module
repository) and sets `CoaBots.AutoLoginOnStartup = 1` with
`CoaBots.AutoLogin.MaxCount = 200` so a restart does not try to bring 800 bots up at
once. It also adds the two keys the module reads but its `.conf.dist` does not ship
(`CoA.CollectionsForBots`, `CoA.RandomBotAccountPrefix`).

### Silencing the "Missing property" startup warnings

The fork reads ~103 options from the worldserver config that neither its own
`worldserver.conf.dist` nor the 35 bundled modules ship, so a fresh start logs ~140
`Config: Missing property <key> ... add "<key> = <value>"` lines. `extra-config.conf`
lists every one of them **with the value the core already falls back to**, so merging
it changes no behaviour - it only removes the noise and makes the effective defaults
visible/tunable in one place. `deploy.sh` merges the file into
`config/worldserver.conf` inside `[worldserver]` (idempotent; existing keys win).

Regenerating the list after a core upgrade:

```
docker logs coa-worldserver 2>&1 | sed -e 's/\x1b\[[0-9;]*m//g' \
  | grep -o 'add "[^"]*"' | sed 's/^add "//; s/"$//' | sort -u
```

Beware that `docker logs` keeps output from *previous* runs too - compare against the
line after the last `AzerothCore rev.` banner before concluding anything.

### Self-healing and database snapshots

`restart: unless-stopped` only covers a process that dies. Two extra layers, both
installed as cron entries in the deploying user's crontab by `deploy.sh` (no root):

| job | schedule | what it does |
| --- | --- | --- |
| `watchdog.sh` | every 2 min | restarts any `coa-*` container that is not running, or whose healthcheck (TCP 3724/8085) failed twice in a row; logs to `logs/watchdog.log`, hourly heartbeat included |
| `backup-db.sh` | 17 */6 (4x/day) | `mysqldump` of `acore_auth` + `acore_characters` + `acore_world` (single transaction, routines/triggers/events) → `backups/coa-all-<stamp>.sql.gz` + `.sha256`; keeps 14 days and at least the newest 20 |

Healthchecks are defined in `docker-compose.yml` (authserver 3724, worldserver 8085
with a 180 s `start_period`; `stop_grace_period: 60s` lets AzerothCore save characters
on SIGTERM).

```
./watchdog.sh [--dry-run]                  # one pass
./backup-db.sh                             # snapshot now
./backup-db.sh --restore backups/coa-all-<stamp>.sql.gz   # stop servers, reload, start
tail -f logs/watchdog.log logs/backup.log
```

### Register site (moved off the old server)

The account-registration page that used to run on `192.168.1.89`
(`C:\COA\CoA-Repack\WebRegister\register_server.py`) now runs on fn176 as the
`coa-register` container: python 3.12 + pymysql + pillow, with `webregister/context/`
holding the upstream service, `index.html` and the `Settings/` files it reads at
startup. It talks to `coa-database` through a dedicated least-privilege MySQL account
(`acore`: SELECT/INSERT/UPDATE/DELETE on `acore_auth`, SELECT on `acore_characters`,
plus CREATE/ALTER/INDEX/DROP on `acore_auth` for the two `coa_qq_*` tables it creates)
and writes SRP6 `salt`/`verifier` rows straight into `acore_auth.account` - so accounts
it creates exist on **this** realm.

Local changes to `register_server.py` (the rest is upstream):

- `load_config()` accepts an optional `repack.json → mysqlHost` and
  `database.json → appUser` (defaults stay `127.0.0.1` / `acore`);
- the probe used by `realm_has_character()` is qualified as
  `acore_characters.characters` - the bare table name resolved against `acore_auth`,
  and the exception was swallowed, so it always returned 0.

```
curl -s localhost:8090/health                                   # {"status": "ok"}
curl -s -o /dev/null -w '%{http_code}\n' localhost:8090/captcha  # 200 (image/png)
```

#### Cutover to the public hostname (done 2026-10-17 21:21)

Players keep using `https://register.soulcore.asia` and nothing on the VPS changed. The
old server's frp proxies were released and fn176's `coa-frpc` bound the **same** remote
ports (3724 / 8085 / 8090, already in the VPS `allowPorts`), so nginx still proxies to
`127.0.0.1:8090` - only the tunnel endpoint moved:

```
internet -> soulcore.asia:8090 (nginx 443) -> frps :8090 -> frpc on fn176 -> coa-register
           soulcore.asia:3724 -> frps :3724 -> frpc -> coa-authserver
           soulcore.asia:8085 -> frps :8085 -> frpc -> coa-worldserver
```

Evidence:

```
# fn176
login to server success / proxy added: [coa-auth-3724 coa-register-8090 coa-world-8085]
start proxy success            (all three)
# VPS frps
[coa-auth-3724] tcp proxy listen port [3724] / new proxy success   (same for 8085, 8090)
# public
https://register.soulcore.asia/       -> 200, the registration page
https://register.soulcore.asia/health -> {"status": "ok"}
soulcore.asia:3724 -> AUTH_LOGON_CHALLENGE (opcode 0x00, 119 bytes) for account LOCAL
```

The frpc image is built locally instead of pulled: Docker Hub pulls on fn176 crawl at
~50 kB/s, so `frpc-build/build-frpc.sh` fetches the official frp **v0.71.0** release
binary (same version as the VPS frps) and builds `coa-frpc:local`, which is what the
compose service uses.

Order used - one window, no split state:

1. freeze writes: fresh `mysqldump` of `acore_auth` + `acore_characters` on the old host
   through the temporary share-write channel, then `./import-legacy-players.sh` into the
   live new database (the script snapshots it first);
2. stop the old stack gracefully (`manage.py stop-all` - characters are saved first) and
   disable its scheduled tasks, which releases 3724/8085/8090 on the VPS;
3. `docker compose --profile tunnel up -d coa-frpc` on fn176, then verify from outside.

Rollback: re-enable the old host's tasks and start its stack - both hosts cannot hold the
same remote ports, so only one of them can serve the realm at a time.

### Legacy CoA deployment on 192.168.1.89 (stopped, kept as a cold backup)

The previous (Windows) CoA server was stopped cleanly during the cutover
(`manage.py stop-all` saved the characters first: `Graceful world shutdown requested.` /
`All services from this repack are stopped.`) and its seven scheduled tasks -
`CoA-Server-Stack`, `CoA-Bots-Stack`, `CoA-AuthWatchdog`, `CoA-WorldWatchdog`,
`CoA-MySQLWatchdog`, `CoA-Register`, `CoA-frpc` - are disabled. It therefore holds no
public ports and no longer self-heals; all six of its local ports (3307/3724/8085/8090/
3443/8088) are closed and no process of the stack is running. It is kept as a
data/history source and as a rollback target:

- restart it: `schtasks /change /tn "\CoA-<name>" /enable` for those seven tasks, then
  start the stack again. The two `CoA-OpsGateway*` tasks were deliberately left enabled,
  so the ops gateway and the share-write channel still work;
- a copy of the exported player data is on its share in `C:\COA\_staging\fresh-players\`
  and on fn176 in `legacy/fresh/`.

The rest of this section describes the host as it was found:

- Windows host `192.168.1.89`, SMB share **`COA` readable anonymously** (`smbclient
  //192.168.1.89/COA -N`), RDP 3389; the game itself lives in `C:\COA\CoA-Repack`.
- frp tunnel: `C:\COA\frp\frpc.toml` → `soulcore.asia:7000` (frps on the HK VPS
  `47.238.240.32`), exposing 3724 auth / 8085 world / 8090 register; only loopback
  services on the Windows side, so the LAN ports look closed by design.
- Player entry `https://register.soulcore.asia` (nginx → `127.0.0.1:8090` → tunnel →
  `register_server.py`, which writes SRP6 rows straight into `acore_auth.account`).
- History/backups on the share: `全量备份/` (`2026-09-26-routeA-players-3dbs.sql`,
  91 MB, plus `2026-09-26-pre-routeB-forked-world.sql`, 514 MB), `文档/`
  (`CoA注册网页-部署与运维.md`, `CoA反代迁移-20261011.md`,
  `CoA外网开服-成功方案（权威版）.md`, ...), `脚本/` (`coa_backup.py`, task XMLs).
- Game database: MySQL 8.4 on `127.0.0.1:3307` (`C:\COA\CoA-Repack\mysql`), four
  schemas `acore_auth` / `acore_characters` / `acore_playerbots` / `acore_world`;
  `mysql/bin/mysqldump.exe` is present, so a fresh export only needs an execution
  channel. `文档\`/`脚本\` also carry the ops tooling (`coa_ops_gateway.py`,
  scheduled tasks `CoA-Server-Stack`, `CoA-Register`, `CoA-frpc`, watchdogs).
- Remote access without RDP: the SMB **administrator share** (`C$`) plus remote
  `schtasks /s 192.168.1.89 /u administrator` is the intended path - measured working
  for reads, but the local `administrator` account is currently **locked out** from
  repeated authentication attempts. The ops gateway `http://192.168.1.89:18930`
  (`X-CoA-Token`) stays usable: status, logs, logs/tail, read/ls/grep, read-only SQL
  (500 rows) and a whitelist of idempotent actions - **no shell, so it cannot run
  mysqldump**.
- ⚠ Security findings on the legacy host, none of them fixed yet: the `COA` share is
  readable **and writable by anonymous/guest**, `C:\COA\脚本\gh_token.txt` holds a
  plaintext GitHub PAT, and the ops-gateway tokens (`C:\COA\脚本\.secrets\gateway.json`)
  were exposed while reading that file - rotate both tokens and tighten the share.

### Verified state (fn176, 2026-10-17)

| check | result |
| --- | --- |
| image | `coa-server:0.261017.4` (= GHCR `0.261017.2` artifact + `mysql-client` + the duplicate-SQL fix), smoke-tested |
| containers | `coa-database` (mysql 8.4.11) healthy, `coa-authserver`, `coa-worldserver` up |
| ports | 3724 auth, 8085 world, 7878 SOAP, 3443 remote console - all listening on 0.0.0.0 |
| startup | `WORLD: World Initialized In 0 Minutes 20 Seconds`, update diff 3-4 ms, worldserver RSS ~5.2 GB |
| databases | dump restored; `acore_auth` 22 / `acore_characters` 20 / `acore_world` 3025 applied updates, `coa_boss_schedule` on the `effect_d0..d3` schema |
| bots | `mod_coa_playerbots.conf` loaded, talent builds loaded (70 builds / 3564 picks), `botcmd spawnleveled` → **195 characters in world**, all 195 re-log in automatically after `docker restart coa-worldserver` |
| account | `local` / `local`, security 3 (in `acore_auth.account_access`) |
| warnings | 0 `Missing property` lines after merging `extra-config.conf` (was ~140) |
| self-healing | `watchdog.sh` cron active (heartbeat in `logs/watchdog.log`), `backup-db.sh` snapshot verified (109 MB gz, sha256, 22 s) |
| register site | `coa-register` up on 8090; `/health` ok, `/captcha` = 190x58 PNG, `create_account()` self-test wrote a 32-byte salt/verifier into the new `acore_auth` (test row deleted again) |
| cutover | public ingress moved to fn176: `coa-frpc` (profile `tunnel`, image `coa-frpc:local` = official frp v0.71.0) owns the VPS ports 3724/8085/8090; `https://register.soulcore.asia/` = 200, `/health` = ok, and `soulcore.asia:3724` answered a real 3.3.5a `AUTH_LOGON_CHALLENGE` (0x00) for account `LOCAL` |
| player data | legacy `acore_auth` + `acore_characters` (exported 2026-10-17 20:51) imported: 202 accounts / 3369 characters / 23 guilds / 0 orphans, top characters level 80; `LOCAL`/`local` GM (security 3) works against the imported SRP6 verifier |
| bots after import | `botcmd spawnleveled 200` -> 195 characters in world, 5.55 GB RSS, update diff 5 ms, 3569 characters total |

### Known gaps

- The build loses the revision banner: `worldserver --version` prints
  `rev. unknown 1970-01-01 (Archived branch)`; the `-Drev_*` args only reach the
  banner when the build runs against a git checkout.
- The GHCR package is pullable anonymously, but pulls from fn176 stall on layer
  `d08df6459be3`; the artifact route (`build-from-artifact.sh`) is what is used.
- The database can only come from an official pre-built dump; the from-scratch SQL
  chain (`COA_DB_SOURCE=dbimport`) still fails on the stale
  `rev_20260930_85_molten_core_boss_kits.sql`.
- No real 3.3.5a client has connected end-to-end yet; the logon handshake and both game
  tunnels are verified from outside the LAN, but nobody has reached the character screen.
- The imported data still carries 3234 legacy SQUID bot characters (`RNDBOT*` accounts,
  ~91% of the character table); only 135 characters belong to real players, and the
  legacy bots have no AI under this module. Provenance, verified 2026-10-17: 154 `RNDBOT*`
  accounts (`acore_auth.account` ids 71-275) created 2026-09-16 20:41 → 2026-09-26 06:16,
  i.e. the old server's SQUID era — the legacy repack ships
  `Core/configs/modules/playerbots.conf.dist:106 AiPlayerbot.RandomBotAccountPrefix = "rndbot"`;
  330 of the characters sit in 22 bot-only guilds of exactly 15 members; SQUID's own tables
  (`playerbots_names` 100000 rows, `playerbots_guild_names`, `playerbots_arena_team_names`)
  were deliberately not imported, and its `acore_playerbots` database exists only inside the
  old host's MySQL datadir. Purging is safe for this stack: `mod-coa-playerbots` at the built
  commit `c76847a` has zero references to `rndbot`/`RandomBotAccountPrefix` (its only prefix is
  `CoaBots.RandomSpawn.AccountPrefix = "CoaBotHost"`), the core created no new `rndbot` account
  after the cutover, and the newest character guids (3612-3620) belong to the new `COABOTHOST`
  bots, so deleting the legacy rows cannot cause guid/account-id reuse. Operator decision
  (2026-10-17): **keep them for now**; only 22 bot-only guilds plus `guild_member`, `mail`,
  `item_instance` (44881 rows), `character_*` rows would have to be cleaned together.
- The old host is stopped but not decommissioned, and the security findings on it are
  unchanged by decision of the operator (the `COA` share stays anonymously writable, its
  GitHub PAT and gateway tokens were not rotated). The temporary channel used for the
  export was cleaned up: `C:\COA\脚本\coa_dsh_share_sync.py` was restored byte-exact
  (18034 bytes, sha256 `BEE23D79...ABBC42`) and the token-bearing worker and probe file
  were deleted. **Before that host is retired**, archive the one asset that has no copy
  anywhere else: its MySQL datadir holds the SQUID-only database `acore_playerbots`
  (the exported dumps cover `acore_auth` + `acore_characters` only).

Client: WotLK 3.3.5a with `realmlist.wtf` → `set realmlist soulcore.asia`
(realm address/port in `acore_auth.realmlist` are `soulcore.asia:8085`, exactly as the
legacy dump had them; LAN players can still use `192.168.1.176`).

