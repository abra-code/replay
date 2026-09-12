# replay installer

Builds `replay_<version>.pkg`, installing `replay`, `dispatch`, `fingerprint`
and `gate` into `/usr/local/bin`. Built with PackageBuilder.app.

This folder is tracked; only `installer/dist/` is gitignored, so the documents,
the generated scripts and the installer resources all reach a clone.

## Two documents, on purpose

| File | Signing | Payload VERIFY | Package name | Use |
|---|---|---|---|---|
| `replay.pkgbld` | on, identity supplied at build time | Developer ID, hardened runtime, secure timestamp, arch, version | `replay_<v>.pkg` | the real distribution build, on the signing machine |
| `replay-local.pkgbld` | off | architecture and version only | `replay_<v>-localtest.pkg` | local smoke build on a machine with no Developer ID |

The split is needed because `--unsigned` skips only the *installer* signature.
The payload assertions still run, so a distribution document cannot be
smoke-built on a machine whose binaries are ad-hoc signed.

The local document deliberately carries a different `PACKAGE_NAME`. Passing
`--identity` to `makepkg-local.sh` overrides its baked `do_codesign=0` and will
sign whatever it is given, with none of the payload assertions in force; the
`-localtest` name is what keeps the result from being mistaken for a release.

Keep the two in step: any change to payload, destinations or presentation
belongs in both.

## Distribution build

Artifacts must already be built and signed with a Developer ID Application
identity, with the hardened runtime and a secure timestamp - that is
`xcodebuild archive`, not `xcodebuild build`, plus `codesign.sh <identity>`.

The identity is not stored in the document, so every command below needs it,
`--dry-run` included; without one the build stops at the preconditions and
never reaches the payload verify that the document exists to run.

```sh
PB="/Applications/PackageBuilder.app/Contents/Resources/Agents/pkgbuilder"
ID="Developer ID Installer: <name> (<TEAMID>)"

"$PB" build installer/replay.pkgbld --dry-run --identity "$ID"
"$PB" build installer/replay.pkgbld --identity "$ID"
```

`replay.pkgbld` is portable: `ARTIFACTS_DIR` is overridable with
`--artifacts-dir`, and the installer resources are stored as
`${PROJECT_DIR}/resources/...`, which resolves against the document.

### Without PackageBuilder, on a CI machine

`makepkg.sh` is generated, and every path it froze at export time can be
overridden at run time. It finds `resources/` relative to itself, so no flag is
needed for those as long as the script and `resources/` travel together;
`--project-dir` points elsewhere if they are kept apart.

```sh
sh installer/makepkg.sh --identity "$ID" \
   --artifacts-dir <build/Release> --output-dir <dist>
```

### Notarize

```sh
xcrun notarytool submit dist/replay_2.2.1.pkg --keychain-profile <profile> --wait
xcrun stapler staple dist/replay_2.2.1.pkg
```

## Local smoke build

```sh
sh installer/makepkg-local.sh
```

Lands `dist/replay_<version>-localtest-unsigned.pkg`. Test-only: macOS will not
install it on another Mac. Do not pass `--identity` to this script.

## Building universal artifacts

`build.sh` does not force `ARCHS`, and `fingerprint` and `gate` come out
arm64-only even though `xcodebuild -showBuildSettings` reports
`ARCHS = arm64 x86_64` and `ONLY_ACTIVE_ARCH = NO` for both schemes.
`fingerprint.xcodeproj` is also the only one of the three projects that emits
`WARNING: Using the first of multiple matching destinations`. Until that is
fixed, force it on the command line:

```sh
for p in "replay.xcodeproj replay" "dispatch.xcodeproj dispatch" \
         "fingerprint.xcodeproj fingerprint" "fingerprint.xcodeproj gate"; do
    set -- $p
    xcodebuild -project "$1" -scheme "$2" -configuration Release \
               ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build
done
```

`build.sh` does exactly this itself now, and checks the result, so the loop
above is only needed to build one tool by hand.

`SYMROOT` is the shared `build/` folder. Note that `xcodebuild clean` on any of
these projects fails outright - "Could not delete build/Release because it was
not created by the build system" - and the four products went missing from
`build/Release` once, immediately after such a failed clean. A plain build of
one project does not disturb the others' products; that was checked, both with
unchanged settings and with `ARCHS` changed. Avoid `clean`; delete
`build/Release` by hand if you need a fresh start.

## Regenerating the export scripts

`makepkg.sh` and `makepkg-local.sh` are generated. After editing a document:

```sh
"$PB" export-script installer/replay.pkgbld       installer/makepkg.sh
"$PB" export-script installer/replay-local.pkgbld installer/makepkg-local.sh
```
