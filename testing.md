# Testing: what gates a release today

What actually runs against every artifact, in increasing strength. Per-package
specifics (test command, extra deps, skip reasons) live in each package's
`flake.nix` and README — this page is only the cross-package picture.

## The layers CI runs on every build

1. **Portability verifier** — per-OS dynamic-link checks
   ([dynamic-link-policy.md](dynamic-link-policy.md)): `statically linked` on
   Linux, `otool -L` allow-list on macOS, no companion DLL / no `lib*.dll`
   import on Windows.
2. **Smoke** — the flake's `smoke` argv (usually `--version`) must exit 0 and
   match `smokePattern`. Runs on every job that can execute the artifact:
   the native jobs directly, `darwin-x86_64` via Rosetta on the arm Mac
   runner, Windows in a separate `smoke_windows` job on a `windows-2022`
   runner. Cross linux arches (i686, ppc64le, riscv64, armv7l) are build-only
   in CI.
3. **Applet sweep** (multicall packages) — every applet declared in
   `manifest.applets_by_target` must dispatch via `--unpin-program` and the
   announced list must match the declaration in both directions. Includes a
   **negative control**: the binary is asked for an impossible program
   (`--unpin-program=unpin-no-such-program`) and must refuse — that's the only
   signal that catches a missing dispatcher, since `unpin/aliases` is written
   from the declaration and stays green even when nothing dispatches.

## Upstream test suites (`doCheck`)

The strongest layer, wired **per package** in the flake, gated on "can this
host execute what it built":

```nix
doCheck = pkgs.stdenv.buildPlatform.canExecute pkgs.stdenv.hostPlatform;
```

That's `true` on the three native jobs — x86_64-linux (`ubuntu-latest`),
aarch64-linux (`ubuntu-24.04-arm`), aarch64-darwin (`macos-14`) — and `false`
on every cross target (Windows, i686/ppc64le/riscv64/armv7l, `darwin-x86_64`).
There is no separate test harness in action-build: the suite runs inside
`nix build`'s check phase on those jobs.

Adoption is incremental. Packages that have wired it include cpio, xz, ed,
gzip, grep, sed, patch, file, brotli, dosfstools, dav1d, coreutils
(Linux-gated); packages where the suite can't or shouldn't run carry an
explicit `doCheck = false` with a one-line reason — the policy for when that's
acceptable is in [releasing.md](releasing.md#native-test-suite) (runaway cost,
static-musl incompatibility, no meaningful suite). A skip must always name its
reason; "it failed" alone is a prompt to investigate, not to flip the flag.

## What doesn't exist (deliberately, so far)

- **No cross-target test execution.** Running upstream suites against the
  Windows `.exe` (e.g. under msys2 on a Windows runner) or against the cross
  linux arches has been sketched but not built; smoke + the applet sweep are
  the only execution those targets get in CI. Local pre-release smoke on real
  Windows/macOS machines is workspace infra, not part of the public pipeline.
- **No `checks.*` flake outputs.** Tests ride the package derivation's check
  phase, so CI needs no extra matrix entries.
