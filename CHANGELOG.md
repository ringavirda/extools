# Changelog

## [0.2.2] - 2026-09-07

A generated tests workflow provisions the dependency mods before the tests, so the harness guards
that read exlib's shipped assets pass in a standalone clone. The starter transform follows exlib's
samples, which now declare `AssetDomain` instead of hand-rolling the asset glob.

## [0.2.1] - 2026-09-07

`format`, `check` and `clean` no longer fail in a repository whose manifest names no samples
(the starter, the family). A generated starter is formatted with the pinned CSharpier before its
first commit.

## [0.2.0] - 2026-09-07

Two commands for a new repository. `exmod starter <dest>` generates the standalone starter
repository from exlib's HelloModule and HelloExpanded samples: the four csproj files and each
modinfo are transformed from the samples' own text (package mode, versions pinned to the exlib
checkout), and the command writes the solution, the launchers, the manifest, the packages props,
CI pinned to a game patch, the dotfiles, an MIT licence template and a README. A re-run
regenerates what it owns and carries forward every mod added since. `exmod new <modid>` scaffolds
an empty mod, or with `--module` an exlib module, into the current repository and registers it in
the manifest and the solution.

## [0.1.2] - 2026-09-07

Output of a build or an archive extraction run inside a helper that returns paths no longer joins
the returned list; the smoke lane on a fresh checkout failed on an empty path where a build had
printed a line. The coverage gate reads the floors file by an explicit path under the repository
root instead of the working directory.

## [0.1.1] - 2026-09-07

A checkout of this repository ends MSBuild's search for Directory.Build.props and .targets, so a
consumer's `.extools/` clone no longer takes that repository's build logic: under exlib, the
publicizer's build inherited the auto-provisioning target and re-entered the provision lock, and
every CI provision hung. The lock wait is bounded at twenty minutes and fails with the cause. The
provisioning web calls time out and retry, and the shared `.game` and `.dotnet` installs are no
longer tracked.

## [0.1.0] - 2026-09-07

The tooling of the Expanded family monorepo in its own repository: the `exmod` dispatcher and
its five stages, the two launchers a consuming repository checks in, the manifest-driven packaging
build, the standalone `exlib-verify` tool, the publicizer, the coverage gate and the released-codes
derivation, and the CI templates. Every repository-specific fact is read from the consuming
repository's `exmod.json`; runtime dependency mods resolve from a workspace sibling or a release.
