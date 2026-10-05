#!/usr/bin/env python3
"""Fetch the pinned workload corpus; SID music stays in git-ignored music/."""
import hashlib
import json
from pathlib import Path
import urllib.request

ROOT = Path(__file__).resolve().parents[2]


def main():
    corpus = json.loads((ROOT / 'tests/heavy-corpus.json').read_text())
    for tune in corpus['tunes']:
        path = ROOT / tune['file']
        if path.exists():
            data = path.read_bytes()
        else:
            with urllib.request.urlopen(tune['source'], timeout=30) as response:
                data = response.read()
        if data[:4] not in (b'PSID', b'RSID') or len(data) < 124:
            raise SystemExit(f"Not a SID file: {tune['source']}")
        if hashlib.sha256(data).hexdigest() != tune['sha256']:
            raise SystemExit(f"Checksum mismatch: {path}; file not overwritten")
        if not path.exists():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        print(f"verified {tune['file']}")


if __name__ == '__main__':
    main()
