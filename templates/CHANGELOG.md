<!--
  Canonical package CHANGELOG. Copy to `<pkg>/CHANGELOG.md`, replace the <…>
  slots, and delete this comment. Filled reference: `tree/CHANGELOG.md`.

  This is the USER-FACING changelog — curated, not the git log. Record only what
  someone running the binary can observe: the packaged upstream version, a
  platform gained/dropped, a feature enabled/disabled, an embedded resource, a
  fix to OUR build. Do NOT log nix-lib pin bumps, README wording, or CI tweaks —
  that noise belongs in git history.

  WORKFLOW: write each change under `## [Unreleased]` as part of the same commit
  that makes it. When the release is cut, the release workflow renames
  `[Unreleased]` to `## [<tag>] - <date>` (computing the auto-incremented
  pkgrel) and uses that section as the body of the GitHub release. You never
  write the version header by hand.
-->
# Changelog

## [Unreleased]

Initial release — `<pkg>` <version> as a single self-contained binary, built
natively for <Linux, macOS, and Windows>.

### Added

- Builds for <Linux (x86_64, …), macOS (x86_64, aarch64), and Windows>.
- `<pkg>.1` man page embedded in the binary — read it with `unpin man <pkg>`.
  <!-- omit if the package ships no man page -->

<!--
  Use the Keep a Changelog categories, omitting any that don't apply:
  ### Added      — a platform, an embedded resource, a feature now built in
  ### Changed    — upstream version bump, a build behavior that shifted
  ### Fixed      — a bug in OUR build (a crash on some target, a dropped file)
  ### Removed    — a platform or feature dropped, with the one-line reason
  ### Deprecated / ### Security — as needed
-->
