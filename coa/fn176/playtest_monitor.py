#!/usr/bin/env python3
"""Watch the CoA server during play tests.

Follows the world/error logs, keeps only lines a human cares about and appends a
health snapshot (with the real players' progress) every 5 minutes.

    nohup setsid ./playtest_monitor.py >/dev/null 2>&1 &
"""
import datetime
import os
import re
import subprocess
import time

BASE = "/vol1/1000/docker/coa-fn176"
LOG = os.path.join(BASE, "logs", "playtest-monitor.log")
FILES = ["logs/Server.log", "logs/Errors.log"]
HEALTH_EVERY = 300
NOISE = re.compile(r"BotMgr heartbeat|Wrong area flag|STUCK-DETECTOR|^FLEE: |Auras: Unknown Shapeshift")

PAT = re.compile(
    r"malformed packet|WorldSocket|HandleAuthSession|\blogged (in|out)\b|\blogin\b|disconnect"
    r"|\bkick(ed|ing)?\b|\bban(ned|ning)?\b|\bcrash\b|assert|Segmentation|exception"
    r"|\bERROR\b|\bFatal\b|\bsaveall\b|shutdown|Kill credit|\bquest (complete|reward)"
    r"|level up|LevelUp|Vera|674968117",
    re.I,
)


def sh(cmd: str) -> str:
    return subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout.strip()


def note(msg: str) -> None:
    with open(LOG, "a", encoding="utf-8") as fh:
        fh.write(datetime.datetime.now().strftime("%F %T") + " " + msg.rstrip() + "\n")


def db_password() -> str:
    try:
        with open(os.path.join(BASE, ".env"), encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("COA_DB_ROOT_PASSWORD="):
                    return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return ""


PW = db_password()
MYSQL = "docker exec coa-database mysql -uroot -p%s -N -e" % PW


def sql(query: str) -> str:
    return sh('%s "%s" 2>/dev/null' % (MYSQL, query))


def snapshot() -> str:
    state = sh("docker inspect coa-worldserver --format '{{.State.Status}} restarts={{.RestartCount}}'")
    usage = sh("docker stats --no-stream --format '{{.MemUsage}} cpu={{.CPUPerc}}' coa-worldserver")
    bots = sql("SELECT COUNT(*) FROM acore_characters.characters c JOIN acore_auth.account a ON a.id=c.account "
               "WHERE c.online=1 AND a.username LIKE 'COABOTHOST%'")
    players = sql("SELECT c.name, c.level, c.xp, c.money, c.zone FROM acore_characters.characters c "
                  "JOIN acore_auth.account a ON a.id=c.account WHERE c.online=1 "
                  "AND a.username NOT LIKE 'COABOTHOST%' AND a.username NOT LIKE 'RNDBOT%'")
    out = f"health: {state} {usage} bots_online={bots}"
    for row in [r for r in players.split("\n") if r.strip()]:
        name = row.split("\t")[0]
        kills = sh("docker exec coa-worldserver grep -ac 'member %s' /azerothcore/env/dist/logs/Server.log" % name)
        out += f" | player {row} kills_credited={kills}"
    dumps = sh("ls -1t %s/*.dmp %s/crashdumps/* 2>/dev/null | head -3" % (BASE, BASE))
    if dumps:
        out += " DUMPS=" + dumps.replace("\n", " ")
    return out


def main() -> None:
    note("monitor started; worldserver image " + sh("docker inspect coa-worldserver --format '{{.Image}}'"))
    offsets = {}
    next_health = time.time()  # snapshot immediately
    while True:
        for rel in FILES:
            path = os.path.join(BASE, rel)
            try:
                size = os.path.getsize(path)
            except OSError:
                continue
            start = offsets.get(rel, size)
            if size < start:
                start = 0
            if size > start:
                try:
                    with open(path, errors="replace") as fh:
                        fh.seek(start)
                        chunk = fh.read()
                        offsets[rel] = fh.tell()
                except OSError as exc:
                    note(f"could not read {rel}: {exc}")
                    continue
                for line in chunk.splitlines():
                    if line and not NOISE.search(line) and PAT.search(line):
                        note(rel + ": " + line)
        if time.time() >= next_health:
            next_health = time.time() + HEALTH_EVERY
            note(snapshot())
        time.sleep(20)


if __name__ == "__main__":
    main()
