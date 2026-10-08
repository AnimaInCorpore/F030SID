# Downloadable Falcon releases

[GitHub Releases](https://github.com/AnimaInCorpore/F030SID/releases) provides
prebuilt downloads so a Falcon user does not need the assembler toolchain.
The initial release is `v0.1`, marked as a preview because physical hardware
validation remains outstanding.

## Assets

| File | Contents |
| --- | --- |
| `F030SID.ZIP` | `F030SID/` with `F030SID.TTP`, generated `DEMO.SID`, `README.TXT`, `COPYING.TXT` and `SOURCE.TXT` |
| `F030SID.TTP` | Standalone player; its DSP kernel and tables are embedded |
| `F030SID-SOURCE.tar.gz` | Matching project source and the pinned reSID source/data, with revision records |
| `SHA256SUMS` | SHA-256 digests of those three assets |

The ZIP is the recommended download. Extract and transfer its folder to a
Falcon030 with DSP56001 and about 1 MB free RAM. Double-click `F030SID.TTP`
and enter `DEMO.SID`; a shell can run `F030SID.TTP DEMO.SID` directly. For
other tunes, supply their `.sid` filename. See [the player docs](player.md).

TOS 4.02 is the emulator-tested configuration; other TOS versions and physical
Falcon playback have not been verified. Single-SID PAL PSID tunes are supported,
subject to the measured [playback limits](heavy-load-check.md). RSID,
interrupt-driven digis, NTSC and extra SIDs remain unsupported.

## Preparing a release

Commit the intended source and documentation, then use a clean checkout:

```sh
make release-assets
make package-gate
```

`release-assets` checks the build/listings, builds the ZIP, copies the player
as `release/F030SID.TTP`, archives the committed project and pinned reSID,
and writes `release/SHA256SUMS`. The archive records source and toolchain
revisions in `SOURCE-REVISION.TXT`. Output files stay in ignored `release/`.

The source archive includes reSID but excludes the separate build toolchain.
An extracted archive has no Git checkout metadata, so clone the toolchain
and select the revision recorded in `SOURCE-REVISION.TXT` before building:

```sh
git clone https://github.com/AnimaInCorpore/f030dsp3d.git third_party/f030dsp3d
git -C third_party/f030dsp3d checkout <recorded-toolchain-commit>
make check package
```

Set local executable paths and install the build dependencies listed in the
main README. A normal Git checkout can instead use the documented
`git submodule update --init` command.

Check the archive contents, the package gate and checksums before publishing.
Create a tag at the tested commit and upload the four assets through GitHub
Releases. Preview notes should include startup instructions, supported files,
known timing failures and whether physical hardware has been tested. Keep
release tags and uploaded assets fixed; publish subsequent changes under a
new version. The source asset includes reSID-derived material and its upstream
notices; the binary ZIP includes the GPL text and source information.
