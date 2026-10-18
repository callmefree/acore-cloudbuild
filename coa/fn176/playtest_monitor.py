#!/usr/bin/env python3
"""Watch the CoA server during a play test.

Follows the world/auth logs, keeps only lines a human cares about (login/logout,
malformed world headers, errors, crashes, the test account) and appends a health
snapshot every 5 minutes.  Writes logs/playtest-monitor.log in the deployment dir.

    nohup setsid ./playtest_monitor.py >/dev/null 2>&1 &
"""
import datetime
import os
import re
import subprocess
import time

BASE = "/vol1/1000/docker/coa-fn176"
LOG = os.path.join(BASE, "logs", "playtest-monitor.log")
FILES = ["logs/Server.log", "logs/Errors.log", "logs/Auth.log", "logs/Playerbots.log"]

PAT = re.compile(
    r"malformed packet|WorldSocket|HandleAuthSession|logged in|logged out|disconnect"
    r"|kick|ban|crash|assert|Segmentation|exception|ERROR|Fatal|saveall|shutdown"
    r"|Vera|674968117|SaveAll|SaveToDB",
    re.I,
)
HEALTH_EVERY = 300


def sh(cmd: str) -> str:
    return subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout.strip()


def note(msg: str) -> None:
    line = datetime.datetime.now().strftime("%F %T") + " " + msg.rstrip()
    with open(LOG, "a", encoding="utf-8") as fh:
        fh.write(line + "\n")


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


def snapshot() -> str:
    state = sh("docker inspect coa-worldserver --format '{{.State.Status}} restarts={{.RestartCount}}'")
    usage = sh("docker stats --no-stream --format '{{.MemUsage}} cpu={{.CPUPerc}}' coa-worldserver")
    online = sh(
        "docker exec coa-database mysql -uroot -p%s -N -e \"SELECT COUNT(*) FROM acore_characters.characters WHERE online=1\" 2>/dev/null"
        % PW
    )
    real = sh(
        "docker exec coa-database mysql -uroot -p%s -N -e \"SELECT c.name,c.level FROM acore_characters.characters c "
        "JOIN acore_auth.account a ON a.id=c.account WHERE c.online=1 AND a.username NOT LIKE 'COABOTHOST%%'\" 2>/dev/null" % PW
    )
    dumps = sh("ls -1t %s/*.dmp %s/crashdumps/* 2>/dev/null | head -3" % (BASE, BASE))
    out = f"health: {state} {usage} online={online}"
    if real:
        out += " player(s)=" + real.replace("\n", "; ")
    if dumps:
        out += " DUMPS=" + dumps.replace("\n", " ")
    return out


def main() -> None:
    note("monitor started; worldserver image " + sh("docker inspect coa-worldserver --format '{{.Image}}'"))
    offsets = {}
    next_health = 0.0
    while True:
        for rel in FILES:
            path = os.path.join(BASE, rel)
            try:
                size = os.path.getsize(path)
            except OSError:
                continue
            start = offsets.get(rel, size)  # start at the current end of file
            if size < start:
                start = 0
            if size > start:
                with open(path, errors="replace") as fh:
                    fh.seek(start)
                    chunk = fh.read()
                    offsets[rel] = fh.tell()
                for line in chunk.splitlines():
                    if PAT.search(line) and "BotMgr heartbeat" not in line:
                        note(rel + ": " + line)
        if time.time() >= next_health:
            next_health = time.time() + HEALTH_EVERY
            note(snapshot())
        time.sleep(20)


if __name__ == "__main__":
    main()
