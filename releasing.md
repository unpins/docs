# Releasing a package

Each unpins package repo ships two workflow files from [`templates/`](templates/):

- `.github/workflows/<pkg>.yml` — **Build**. Fires on every `push` to `main` (and on `workflow_dispatch`). Cross-builds every platform the flake supports, runs the package's `checkPhase` on the native jobs where the flake enables `doCheck` (see [Native test suite](#native-test-suite) below), runs the dynamic-link verifier (see [dynamic-link-policy.md](dynamic-link-policy.md)), and uploads artifacts as workflow-run artifacts. No tag, no GitHub release. Use to validate a change before cutting a release.

- `.github/workflows/release.yml` — **Release**. `workflow_dispatch`-only. Computes the next tag, pushes it, then delegates to `action-build`'s `release.yml` reusable workflow, which builds again on the tag and creates the GitHub release with the binaries attached.

## Pre-release review checklist

Run through this before dispatching the Release workflow. Goal is one quick pass that catches the things CI doesn't already enforce.

### Build all targets locally

Native runners only exist for the host you have. Everything else must build via cross from a host you do have. Hash matches CI for cross-from-x86_64-linux and cross-within-darwin; differs for cross-from-x86_64-linux to aarch64-linux/armv7l-linux (those are CI-native, locally cross-only). Goal is "compiles" — bit-identity is CI's job.

From `x86_64-linux`:

```bash
nix build .#packages.x86_64-linux.default \
          .#packages.x86_64-linux.linux-i686 \
          .#packages.x86_64-linux.linux-ppc64le \
          .#packages.x86_64-linux.linux-riscv64 \
          .#packages.x86_64-linux.windows-x86_64 \
          --no-link --print-out-paths --impure
```

`aarch64-linux` and `armv7l-linux` aren't exposed as cross-from-x86_64 attrs on the flake (CI does them native on `ubuntu-24.04-arm`). For local-only sanity, do it via an ad-hoc `--impure --expr` that targets `pkgsCross.aarch64-multiplatform.pkgsStatic.<pkg>` and `pkgsCross.armv7l-hf-multiplatform.pkgsStatic.<pkg>` and re-applies any consumer overrides (patches, postBuild, etc.). Not bit-identical to CI but confirms the source cross-compiles.

(Note: `pkgsCross.muslpi` was the previous armv7l proxy but it actually targets armv6l — Raspberry Pi 1 / Zero. armv6 lacks hardware 64-bit atomics, so anything that touches `_Atomic uint64_t` links against `libatomic` and breaks the static-only chain. armv7l-hf-multiplatform is the right proxy: hardware float, hardware 64-bit atomics via LDREXD/STREXD, matches what CI's `ubuntu-24.04-arm` runner exercises.)

From an Intel Mac (`x86_64-darwin`):

```bash
nix build .#packages.x86_64-darwin.default --no-link --print-out-paths
# aarch64-darwin via ad-hoc cross expr if the flake has overrides;
# otherwise just `pkgs.pkgsCross.aarch64-darwin.pkgsStatic.<pkg>`.
```

`aarch64-darwin` native still needs Apple Silicon (CI `macos-14`). Local cross-from-Intel is good enough for compile-sanity.

### Native test suite

The functional smoke test (`smoke`/`smokePattern`) only proves the binary launches and prints its version. The upstream **test suite** is a much stronger check — and it *can* run, but only on a host that can execute what it built. Cross targets (Windows, i686, ppc64le, riscv64, and any cross-from-x86_64 darwin/arm) build test binaries for a foreign machine, so their `checkPhase` is skipped no matter what. The **native** jobs are different: x86_64-linux, aarch64-linux (`ubuntu-24.04-arm`), x86_64-darwin and aarch64-darwin (`macos-14`) each run on their own arch, so `make check` runs there for real.

Wire it into the flake's build derivation gated on "not cross", so it runs on every native runner and auto-skips the rest:

```nix
# in the build = pkgs: closure, on the overrideAttrs of the static package
doCheck = pkgs.stdenv.buildPlatform.canExecute pkgs.stdenv.hostPlatform;
```

`pkgsStatic` is still `build == host` for the native arch, so this is `true` on all four native jobs and `false` for every cross. **Enable it wherever the suite passes** under `pkgsStatic`-musl (and, separately, under darwin-static — the two can diverge, so gate further with `lib.optionalAttrs` / `stdenv.hostPlatform.isLinux` if only one side cooperates).

Where it does **not** pass, or isn't worth it, leave `doCheck = false` with a one-line reason — same policy as a disabled feature. The recurring causes:

- **Impractical / runaway cost** — the suite downloads large fixtures or runs for hours (`aom` pulls ~GB of AV1 test vectors; `coreutils`/`bash` suites fork hundreds of helper processes).
- **Breaks under static-musl** — tests that need `/proc`, locale data, DNS, a writable FHS, or a dynamic loader (`dlopen` plugins) that musl-static stubs out.
- **No suite** — codec/data libs with nothing meaningful to run.

The smoke test is the floor and runs unconditionally; `doCheck` is the stronger gate layered on top wherever the suite cooperates. Note any package left at `doCheck = false` in the README's build-notes the same way a disabled feature is noted.

### README must declare

- **Windows variant**: `mingw` or `cosmo`, with a one-sentence reason if `cosmo` (e.g. `tree`: `msvcrt readdir` drops CJK filenames silently — see [platforms/cosmocc.md](platforms/cosmocc.md)).
- **Embedded resources**: list anything that's baked into the binary instead of shipped as a sibling data file (terminfo, magic database, zoneinfo, syntax files). If a resource could not be embedded, state which one and why (size, runtime constraint, no upstream support). Man pages are embedded by default (`embedMan`) for every package, so they don't need a per-package mention — verify presence in the "Embedded man present" step below instead.
- **Disabled features / `--disable-*` flags**: each one with a one-sentence reason (missing on musl, breaks static link, drags in a dynamic dep, etc.).
- **Platforms excluded** from the matrix (`linuxOnly`, Windows-only, no aarch64-darwin, etc.) with the reason (kernel-only API, infeasible static toolchain, …).

### Embedded man present

`embedMan` is default-on, but `withMan` **warns and skips** rather than failing the build (a missing-binary / `binName` mismatch must never break an unrelated package). So a release can silently ship with **no** embedded man. The roff lives as `unpin/man/<name>.<section>` entries in the embedded `unpin/` ZIP (see [embedded-metadata.md](embedded-metadata.md)); the central directory stores those names in plaintext, so confirm they're present for every package that has upstream man pages:

```bash
grep -qa 'unpin/man/' result/bin/<pkg> \
  && echo "man embedded" || echo "NO embedded man"
```

(For an *installed* package you can instead use the stable interface: `unpin bundle list <pkg> | grep '^unpin/man/'`.)

Check **per platform** — the ZIP is built independently on each (native objcopy add-section, Mach-O tail-append, Windows/cosmo tail-ZIP), and the man is sourced differently per target. Common silent-skip causes to rule out:

- **Manual native wiring.** A package that sets `nativeBuild = false` and assembles `packages.<sys>.default` itself (e.g. `gvim`) bypasses `mkStandaloneFlake`'s automatic `withMan` — it must call `lib.withMan` on its own derivation, or it ships man-less.
- **Cross has no man to harvest.** Windows/cosmo cross builds produce no `share/man`, so `mkStandaloneFlake` sources it from `x86_64-linux.<pkgsAttr>`. If the nixpkgs attr name differs from the package name (no `<pkgsAttr>` attr → `null`), supply the man explicitly via `manRoot` (see `gvim.exe` sourcing from `vim-full`).
- **`binName` mismatch.** If the shipped binary isn't `<name>`, pass `binName` so `withMan` can find it.

Packages that legitimately have no man (codec libs, `coreutils`/`busybox` without help2man) are expected to skip — note them in the README's embedded-resources list rather than chasing the warning. See [embedded-man.md](embedded-man.md).

### CI green

The Build workflow on `main` must be green across all matrix jobs before dispatching Release. CI runners cover the native paths your local box can't reach: `aarch64-linux` + `armv7l-linux` on `ubuntu-24.04-arm`, `aarch64-darwin` on `macos-14`, Windows on `windows-latest`.

## Cutting a release

After the Build workflow has gone green on `main`:

```bash
gh workflow run release.yml -R unpins/<pkg>
```

That's it. The reusable workflow handles tag computation, multi-platform build, asset upload, and Cachix push.

## Tag format

Depends on the `own_software` flag passed to `mkStandaloneFlake`:

| `own_software` | Tag format | Use for | Behavior |
| -------------- | ---------- | ------- | -------- |
| `false` (default) | `v<upstream>-<pkgrel>` | Third-party tools | `<pkgrel>` auto-increments from the highest existing `v<upstream>-N` tag. Lets you ship multiple packaging revisions per upstream version. |
| `true` | `v<upstream>` | First-party software (`unpin` itself) | No pkgrel. Errors if the tag already exists — bump the `version` attr in `flake.nix` before re-running. |

`<upstream>` is read from `nix eval .#default.version` — i.e. whatever the upstream's package version is in nixpkgs (or your own `version` attr for first-party software).

## Bumping upstream

To pick up a new upstream version:

```bash
cd <pkg>
nix flake update                                      # bumps nixpkgs + nix-lib pins
# Run the full local cross matrix from the pre-release checklist above.
git add flake.lock
git commit -m "Bump <pkg> to <new version>"
git push
```

Build CI will fire on the push. When green, dispatch the Release workflow as above.

If you need to ship a packaging-only fix at the **same** upstream version (a new patch, a flag change, a fixes-registry tweak), do *not* bump `flake.lock` — just commit and dispatch. The Release workflow auto-increments `<pkgrel>` to the next free integer.

## After the release

1. **Bump the website if the upstream version changed.** The `version` column in `packages.html` is regenerated by `gen-packages.py`:

   ```bash
   cd ../website
   python3 gen-packages.py
   git add packages.html
   git commit -m "Bump <pkg> to <new version>"
   git push
   ```

   The `website/` repo is independent — commit and push there.

2. **No manual download-URL bookkeeping is needed.** The `unpin` CLI resolves `unpin install <pkg>` against `github.com/unpins/<pkg>/releases/latest`. As soon as the release exists, `unpin install` picks it up.

## Cachix

Build and Release push to `unpins.cachix.org` via `CACHIX_AUTH_TOKEN`. The token is an org-level secret — new repos inherit it via `secrets: inherit` in the workflow files. If a fresh repo can't push to Cachix, the org secret is missing or the workflow file forgot `secrets: inherit`.

## Common failure modes

- **`v<upstream>` already exists, `own_software=true`.** Bump the `version` attr in `flake.nix`. Don't force-push the tag.
- **Tag pushed but the tagged build fails.** Fix the build, push to `main`, dispatch Release again — `<pkgrel>` will increment. The bad tag stays in history; that's fine since no GitHub release ever pointed at it.
- **`gh workflow list` doesn't show Release.** `.github/workflows/release.yml` isn't on `main` yet — push it before dispatching.
- **Build green, Release red on the same commit.** Usually means the cross-build path that's only exercised by Release (different runner, different cache state) hits a transient. Re-dispatch first; if it's deterministic, drop into the failing runner's logs.
