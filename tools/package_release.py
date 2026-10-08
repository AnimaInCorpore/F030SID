#!/usr/bin/env python3
"""Prepare GitHub release assets and matching source from a clean checkout."""
import gzip
import hashlib
import io
from pathlib import Path
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]


def git(*args, cwd=ROOT):
    return subprocess.check_output(['git', *args], cwd=cwd)


def main():
    if git('status', '--porcelain', '--untracked-files=normal').strip():
        raise SystemExit('Commit or resolve working-tree changes before packaging a release.')
    revision = git('rev-parse', 'HEAD').decode().strip()
    dependencies = {}
    for name in ('resid', 'f030dsp3d'):
        path = f'third_party/{name}'
        dependencies[path] = git('ls-tree', 'HEAD', path).decode().split()[2]
        actual = git('rev-parse', 'HEAD', cwd=ROOT / path).decode().strip()
        if actual != dependencies[path]:
            raise SystemExit(f'{path} is not at its recorded revision.')

    output = ROOT / 'release'
    source = output / 'F030SID-SOURCE.tar.gz'
    prefix = 'F030SID-SOURCE/'
    archives = [git('archive', '--format=tar', f'--prefix={prefix}', revision),
                git('archive', '--format=tar', f'--prefix={prefix}third_party/resid/',
                    dependencies['third_party/resid'], cwd=ROOT / 'third_party/resid')]
    epoch = int(git('show', '-s', '--format=%ct', revision))
    with source.open('wb') as raw:
        with gzip.GzipFile(fileobj=raw, filename='', mode='wb', mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode='w|') as merged:
                for data in archives:
                    with tarfile.open(fileobj=io.BytesIO(data), mode='r:') as archive:
                        for member in archive:
                            merged.addfile(member, archive.extractfile(member) if member.isfile() else None)
                records = f'F030SID {revision}\n' + ''.join(
                    f'{path} {commit}\n' for path, commit in dependencies.items())
                content = records.encode('ascii')
                member = tarfile.TarInfo(prefix + 'SOURCE-REVISION.TXT')
                member.size, member.mtime, member.mode = len(content), epoch, 0o644
                merged.addfile(member, io.BytesIO(content))

    shutil.copyfile(output / 'f030sid.ttp', output / 'F030SID.TTP')
    names = ('F030SID.ZIP', 'F030SID.TTP', 'F030SID-SOURCE.tar.gz')
    checksums = ''.join(f'{hashlib.sha256((output / name).read_bytes()).hexdigest()}  {name}\n'
                        for name in names)
    (output / 'SHA256SUMS').write_text(checksums, encoding='ascii')
    print(f'Release assets prepared from {revision}:')
    print(checksums, end='')


if __name__ == '__main__':
    main()
