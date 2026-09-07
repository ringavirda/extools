# extools

The build and release tooling for Vintage Story mods built on Expanded Library: `exmod`, one
CLI for the whole lifecycle of a repository (provision the toolchain and the game, build, test,
format, verify shipped assets, run a client or a server, smoke-boot, package, release), the
packaging build it drives, the `exlib-verify` tool, and the helper scripts behind them.

## Using it from a repository

A consuming repository checks in two files and a pin:

```
scripts/exmod.sh     the POSIX launcher   (copy of wrappers/exmod.sh)
scripts/exmod.ps1    the PowerShell launcher (copy of wrappers/exmod.ps1)
exmod.json           "tools": "<version>" plus what the repository holds
```

Both launchers find this checkout in the same order and stop at the first that holds `exmod.ps1`:
the `EXTOOLS_HOME` environment variable; the workspace sibling `../extools`; a clone of the pinned
tag under `.extools/` (made on first use, moved when the pin changes; `EXTOOLS_URL` overrides the
clone source). They then run the dispatcher with the repository as its root. `bash scripts/exmod.sh`
lists every command; `exmod help <command>` describes one. The repository's `exmod.json` names its
mods, samples, test projects, packable projects, game series and dependencies; the field list is in
the Expanded Library wiki under Getting Started, "exmod in your repo".

## Layout

```
exmod.ps1        the dispatcher: argument helpers, the manifest resolvers, command registration, help
exmod/           one file per lifecycle stage: provision, src, run, dist, windows
wrappers/        the two launchers a consuming repository checks in
scripts/         the launchers again, pointed at this checkout, so extools drives itself
pack/            the packaging build (Cake Frosting), manifest-driven
verify/          exlib-verify, a .NET tool that checks a mod's shipped assets with no game running
tools/           the API publicizer provisioning applies, the coverage gate, the released-codes derivation
templates/ci/    GitHub Actions templates for a consuming repository
```

## Releasing

Bump `"tools"` in `exmod.json` (it is also `exlib-verify`'s package version), note the change in
`CHANGELOG.md`, tag `v<version>`, push the tag. A consuming repository moves by editing its own
`"tools"` pin.

## Developing

`bash scripts/exmod.sh test latest` builds and tests the verify tool against a provisioned game
install (`bash scripts/exmod.sh provision game -Kind server` fetches the dedicated-server archive,
which needs no licence). The scripts are PowerShell 7; `exmod.sh` installs `pwsh` into
`.dotnet/tools` when the machine has none.

MIT licensed.
