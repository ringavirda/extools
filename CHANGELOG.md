# Changelog

## [0.1.0] - 2026-09-07

The tooling of the Expanded family monorepo in its own repository: the `exmod` dispatcher and
its five stages, the two launchers a consuming repository checks in, the manifest-driven packaging
build, the standalone `exlib-verify` tool, the publicizer, the coverage gate and the released-codes
derivation, and the CI templates. Every repository-specific fact is read from the consuming
repository's `exmod.json`; runtime dependency mods resolve from a workspace sibling or a release.
