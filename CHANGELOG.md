# Changelog

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
