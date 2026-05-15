# Architecture

## What ships

Each `unpins/<pkg>` repository ships **one executable per OS** plus an optional `.tar.zst` data archive (man pages, completions, runtime data). The binary must run on a stock system with only what the OS itself provides — see [dynamic-link-policy.md](dynamic-link-policy.md).

## Workspace layout

Top-level directories are **independent git repositories**:

| Path | Purpose |
| ---- | ------- |
| `unpin/` | The Rust CLI installer (`unpin install <pkg>`). |
| `nix-lib/` | Shared Nix helpers: `mkStandaloneFlake` template and the per-package `fixes` registry. |
| `cosmocc/` | Cosmopolitan 4.x toolchain packaged as a Nix derivation; exposes `lib.cosmoStdenv`. |
| `htop/`, `jq/`, `tmux/`, `tree/`, `vim/`, `gvim/`, `curl/`, `coreutils/`, `tar/`, `file/` | Package flakes. |
| `action-build/` | Reusable GitHub Actions workflows that build, verify, and release each flake. |
| `website/` | Site source (`unpins.org`). |
| `playground/` | Work-in-progress packages, not consumed by `unpin` or the website. Each entry is either blocked on an upstream issue (bash, coreutils, git) or a recipe/POC kept around for reference (dash, static-gtk2-recipe). |

The local `/home/<user>/projetos/unpins/` directory is a **view** of those independent repos — it is not itself a git repo. Commit and push in the package's own directory.

## `mkStandaloneFlake`

Every package flake calls `unpins-lib.lib.mkStandaloneFlake { name = "<pkg>"; ... }`. The template emits:

```
packages.<system>.default                        — native pkgsStatic build
packages.aarch64-darwin."darwin-x86_64"           — cross within darwin
packages.x86_64-linux."windows-x86_64"            — mingw cross from linux
apps.<system>.default                             — `nix run` entry
manifest                                          — read by action-build for CI config
```

### Parameters

| Argument | Default | Purpose |
| -------- | ------- | ------- |
| `self` | required | The consumer flake's `self`. |
| `name` | required | Package name; also the lookup key in the `fixes` registry. |
| `build` | `null` | Explicit native builder `pkgs -> drv`. When `null`, the registry's `fixes.<name>.native` is used, falling back to `pkgs.pkgsStatic.<name>`. |
| `windowsBuild` | `null` | Explicit mingw builder. When `null`, `fixes.<name>.mingw` is used, falling back to `(mingwStaticCross pkgs).<name>`. |
| `binName` | `name` | Override for `apps.default` when the binary's name differs from the package name. |
| `nativeBuild` | `true` | Set to `false` for Windows-only packages (no native build is emitted). |
| `windows` | `false` | Set to `true` to enable the registry's mingw path. (`windowsBuild` not null also enables it.) |
| `package_data` | `true` | Tells action-build to also publish `result/share` as a `.tar.zst`. |
| `bootstrap_naming` | `false` | Used by `unpin/` itself for the bootstrap asset name convention. |
| `own_software` | `false` | Marks `unpin/` itself (and any future first-party tool) — affects release notes. |

### Output post-processing

The template normalizes single- vs multi-output drvs into a single `result/` symlink so action-build's verifier finds the binary at `result/bin/<pkg>` regardless of the upstream output structure. It also runs `dropSharedLibs` to remove stray `.so`/`.dylib`/`.dll`/`.dll.a`/`.la` artifacts from any output that fell back to non-static dependencies (a no-op for `pkgsStatic` outputs, which already produce only `.a`).

## The `fixes` registry

`nix-lib/flake.nix` exposes a name-keyed `fixes` table with up to three platform sub-keys:

```nix
fixes = {
  <name>.native       = pkgs: drv;          # terminal native (pkgsStatic) build
  <name>.mingw        = pkgs: drv;          # terminal mingw cross build
  <name>.mingwOverlay = self: super: drv;   # transitive dep; consumed by mingwStaticCross
};
```

`mkStandaloneFlake` looks up `fixes.<name>.{native,mingw}` automatically. `mingwOverlay` entries are stitched into the cross package set by `mingwStaticCross`, so curl, ffmpeg, etc. transparently see the fixed `libidn2` / `libpsl` / etc.

**Add platform branching as a registry entry, not as a conditional inside the consumer flake.** Consumer flakes should only set `build` / `windowsBuild` when the build is fully custom (Vim's `Make_ming.mak`, curl's Schannel build, gvim's Win32 GUI, etc.).

Examples currently in the registry: `htop.native` (darwin `--enable-static` filter), `tmux.native` (darwin dep-prune + resolv removal), `coreutils.native` (drop multicall symlinks), `tar.native` / `tar.mingw` (rename `bsdtar` → `tar`, drop the other libarchive utils), `jq.mingw` (winpthread + `-all-static` + `bin/jq.exe` reference fix), `libidn2.mingwOverlay` and `libpsl.mingwOverlay` (curl static chain).

## `mingwStaticCross pkgs`

A helper in `nix-lib` that returns `pkgsCross.mingwW64` plus an overlay that:

1. Wraps the stdenv with `makeStaticLibraries` — injects `--enable-static --disable-shared` for autotools, `-DBUILD_SHARED_LIBS=OFF` for cmake, `-Ddefault_library=static` for meson into every `mkDerivation`.
2. Sets `stdenv.hostPlatform.isStatic = true`. A small lie at the platform-attr level (not a re-instantiation) — upstream recipes key off `isStatic` directly (`zlib`'s `shared ? !isStatic`, etc.) and produce `.a`-only outputs.
3. Stitches in every `fixes.<name>.mingwOverlay` entry as part of the overlay.

`pkgsCross.mingwW64.pkgsStatic` is **not** used because it re-instantiates nixpkgs with `crossSystem.isStatic = true` → cross GCC rebuilds against modified `windows.mingw_w64`/`mcfgthread` configureFlags → ~30 min toolchain rebuild for byte-identical output.

## `mingwStaticBinary`

Companion helper that finalizes a mingw binary for shipping. Adds the piece the per-library adapter can't: libtool-aware `LDFLAGS=-all-static` at make time, so the *final* link resolves to `.a` only (without it, libtool picks `.dll.a` and the DLL-link hook copies the matching `.dll` next to the binary).

Used by consumer flakes (e.g. `curl`) that need fine control over `staticDeps`, `extraInputs`, `extraConfigureFlags`, and `extraCFlags` (for `*_STATICLIB` defines).

## `nix-lib` scope

Every package flake calls `mkStandaloneFlake`. Beyond that, packages tap into `nix-lib` at different depths:

- **Pure default** — `tree`, `jq`: just `pkgs.pkgsStatic.<pkg>`, optionally a `fixes.<name>.mingw` entry for transitive quirks.
- **Registry-only fixes** — `htop`, `tmux`, `coreutils`, `tar`: `pkgsStatic` works on Linux but needs small overrides on darwin or mingw. The override lives in `fixes.<name>.{native,mingw}`.
- **`mingwStaticBinary` + the `mingwOverlay` chain** — `curl` (libpsl/libidn2/libunistring chain), `playground/ffmpeg` (codec libs). Substantial static-dep chains that benefit from the full toolbox.
- **Custom `build` / `windowsBuild`** — `vim`, `gvim`, `file`: don't fit `pkgsStatic.<name>` at all (Vim's `Make_ming.mak`, gvim's GTK2 stack, file's libgnurx rebuild). The consumer flake supplies the build directly.

**Rule:** add a helper to `nix-lib` when (a) the pattern is non-trivial enough to bury in a function and (b) there are ≥ 2 callers *today*, not hypothetical. 1-line `overrideAttrs` wrappers fail both bars. If a new package matches cross-mingw-with-static-deps (curl/ffmpeg pattern), it joins the club; otherwise leave the override inline in the consumer flake.

## Verifying refactors

After touching `nix-lib`, drv-hash diff each consumer flake against the cached version to confirm a byte-equivalent refactor:

```bash
cd <pkg>
nix eval --override-input unpins-lib path:../nix-lib \
  .#packages.<system>.<output>.drvPath
```

A mismatch means the refactor changed the output. State a reason (intentional behavior change, upstream version bump, etc.) before merging.
