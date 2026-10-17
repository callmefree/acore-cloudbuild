#!/usr/bin/env python3
"""Restore CoA.PlaintextWorldHeaders for clients running the *original* Extensions.dll.

Background
----------
Upstream commit 2d13ffd73a (2026-09-28, "refactor(CoA): talk to the client through
native Extensions.dll packets only (#5507)") removed the plaintext world-header mode:
WorldSocket always initialises the header crypt after a valid login.  Clients whose
Extensions.dll is the original (not the reconstructed) one keep sending world packet
headers *unencrypted*, so the server decrypts plaintext bytes, rejects them with

    WorldSocket::ReadHeaderHandler(): client <ip> sent malformed packet
      (raw: 000CDC010000, cryptInitialized: true, size: ..., cmd: ...)

and closes the socket a few seconds after login - the client shows "连接服务器失败"
("connection to the server failed") right after the realm selection.

Upstream added the option back in 00fbffd1d4 ("Net: bring back CoA.PlaintextWorldHeaders
as an option (default on in the dist)") and reverted it 11 minutes later in 504fa66b83,
so it is absent from the coa-bots branch we build from.  This script re-applies exactly
those edits.  It is deliberately written as anchored string replacements with hard
asserts instead of `git apply` so that unrelated drift in the fork cannot make it fail
silently or partially.

The mode stays gated upstream: it only takes effect for loopback clients or when
`CoA.AllowRemoteClients = 1`, and only when `CoA.PlaintextWorldHeaders = 1` is set
(see coa/fn176/extra-config.conf).

Usage: apply-plaintext-headers.py <core-checkout>
"""

import pathlib
import sys


def patch(path: pathlib.Path, old: str, new: str, count: int = 1) -> None:
    text = path.read_text(encoding="utf-8")
    found = text.count(old)
    assert found == count, f"{path}: expected {count} occurrence(s) of anchor, found {found}"
    path.write_text(text.replace(old, new, count), encoding="utf-8")
    print(f"patched {path}")


def main() -> int:
    core = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    cpp = core / "src/server/game/Server/WorldSocket.cpp"
    hdr = core / "src/server/game/Server/WorldSocket.h"
    dist = core / "src/server/coa/conf/coa.conf.dist"
    for required in (cpp, hdr):
        assert required.is_file(), f"missing {required}"

    patch(
        hdr,
        "    bool _ascensionCompatEnabled = false;\n",
        "    bool _ascensionCompatEnabled = false;\n"
        "    bool _usePlaintextWorldHeaders = false;\n",
    )

    patch(
        cpp,
        "    _ascensionCompatEnabled = allowAscensionClient &&\n"
        '        sConfigMgr->GetOption<bool>("CoA.Enable", false, false);\n',
        "    _ascensionCompatEnabled = allowAscensionClient &&\n"
        '        sConfigMgr->GetOption<bool>("CoA.Enable", false, false);\n'
        "    _usePlaintextWorldHeaders = allowAscensionClient &&\n"
        '        sConfigMgr->GetOption<bool>("CoA.PlaintextWorldHeaders", false, false);\n',
    )

    patch(
        cpp,
        "    AccountInfo account(result->Fetch());\n",
        "    AccountInfo account(result->Fetch());\n"
        "\n"
        "    bool const usePlaintextWorldHeaders = _usePlaintextWorldHeaders;\n",
    )

    patch(
        cpp,
        "    if (!sToCloud9Sidecar->ClusterModeEnabled())\n",
        "    if (!sToCloud9Sidecar->ClusterModeEnabled() && !_authCrypt.IsInitialized() && !usePlaintextWorldHeaders)\n",
    )

    if dist.is_file():
        patch(
            dist,
            "CoA.AllowRemoteClients = 0\n",
            "CoA.AllowRemoteClients = 0\n"
            "\n"
            "# The original Extensions.dll keeps world packet headers unencrypted after a\n"
            "# valid login; 1 accepts/sends plain headers (needs loopback or CoA.AllowRemoteClients),\n"
            "# 0 uses the stock header cipher (reconstructed Extensions.dll). Restart to apply.\n"
            "CoA.PlaintextWorldHeaders = 1\n",
        )
        print(f"patched {dist}")
    else:
        print(f"note: {dist} not present, skipped")

    text = cpp.read_text(encoding="utf-8")
    assert "!_authCrypt.IsInitialized() && !usePlaintextWorldHeaders" in text
    assert 'GetOption<bool>("CoA.PlaintextWorldHeaders", false, false)' in text
    print("ok: plaintext world-header compatibility re-applied")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
