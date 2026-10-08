# Downloadable Falcon releases

[GitHub Releases](https://github.com/AnimaInCorpore/F030SID/releases) provides
prebuilt downloads so a Falcon user does not need the assembler toolchain.
The current published release is [v0.1](https://github.com/AnimaInCorpore/F030SID/releases/tag/v0.1),
created on 2026-10-08 at commit `4781be06dfb8a62fa90ab1aee14b6d33e5d1184f`.
It is marked as a preview because physical hardware validation remains
outstanding. The tag and assets describe that snapshot; current checkout
documentation may include later corrections.

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
subject to the measured [playback limits](performance.md#two-minute-load-check). RSID,
interrupt-driven digis, NTSC and extra SIDs remain unsupported.

## Validation of v0.1

`make check` passes with clean DSP assembler listings. The packaged demo gate
passes both 6581 and 8580 for 32 seconds: 1,573,438 frames per model,
32.02 seconds elapsed, minimum ring fill 3563 of 3584 frames, matching
reference checksums and no overtakes or SSI underrun flag. The published
player's SHA-256 is
`0ec20ffef469928b38275079924a5fc02dbba5f060f2e8c14ef4e3ec56f7072b`,
matching the player used for the [2026-10-05 load check](performance.md#two-minute-load-check).
These are emulator checks, not physical-Falcon validation.

## Preparing a release

Commit the intended source and documentation, then use a clean Git checkout
with both submodules initialized at their recorded revisions:

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
toolchain_rev=$(awk '$1 == "third_party/f030dsp3d" {print $2}' SOURCE-REVISION.TXT)
git -C third_party/f030dsp3d checkout "$toolchain_rev"
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
