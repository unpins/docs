# Releasing a package

Each unpins package repo ships two workflow files from [`templates/`](templates/):

- `.github/workflows/<pkg>.yml` — **Build**. Fires on every `push` to `main` (and on `workflow_dispatch`). Cross-builds every platform the flake supports, runs the dynamic-link verifier (see [dynamic-link-policy.md](dynamic-link-policy.md)), and uploads artifacts as workflow-run artifacts. No tag, no GitHub release. Use to validate a change before cutting a release.

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

`aarch64-linux` and `armv7l-linux` aren't exposed as cross-from-x86_64 attrs on the flake (CI does them native on `ubuntu-24.04-arm`). For local-only sanity, do it via an ad-hoc `--impure --expr` that targets `pkgsCross.aarch64-multiplatform.pkgsStatic.<pkg>` and `pkgsCross.muslpi.pkgsStatic.<pkg>` and re-applies any consumer overrides (patches, postBuild, etc.). Not bit-identical to CI but confirms the source cross-compiles.

From an Intel Mac (`x86_64-darwin`):

```bash
nix build .#packages.x86_64-darwin.default --no-link --print-out-paths
# aarch64-darwin via ad-hoc cross expr if the flake has overrides;
# otherwise just `pkgs.pkgsCross.aarch64-darwin.pkgsStatic.<pkg>`.
```

`aarch64-darwin` native still needs Apple Silicon (CI `macos-14`). Local cross-from-Intel is good enough for compile-sanity.

### README must declare

- **Windows variant**: `mingw` or `cosmo`, with a one-sentence reason if `cosmo` (e.g. `tree`: `msvcrt readdir` drops CJK filenames silently — see [platforms/cosmocc.md](platforms/cosmocc.md)).
- **Embedded resources**: list anything that's baked into the binary instead of shipped as a sibling data file (terminfo, magic database, zoneinfo, syntax files). If a resource could not be embedded, state which one and why (size, runtime constraint, no upstream support).
- **Disabled features / `--disable-*` flags**: each one with a one-sentence reason (missing on musl, breaks static link, drags in a dynamic dep, etc.).
- **Platforms excluded** from the matrix (`linuxOnly`, Windows-only, no aarch64-darwin, etc.) with the reason (kernel-only API, infeasible static toolchain, …).

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
