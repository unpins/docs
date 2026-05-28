# Architecture

## What ships

Each `unpins/<pkg>` repository ships **one executable per OS** plus an optional `.tar.zst` data archive (man pages, completions, runtime data). The binary must run on a stock system with only what the OS itself provides — see [dynamic-link-policy.md](dynamic-link-policy.md).

## Workspace layout

Top-level directories are **independent git repositories**:

| Path | Purpose |
| ---- | ------- |
| `unpin/` | The Rust CLI installer (`unpin install <pkg>`). |
| `nix-lib/` | Shared Nix helpers: `mkStandaloneFlake` template, cross-overlay fragments (`native-overlay/`, `mingw-overlay/`, `cosmo/`) for transitive lib deps, and the bundled Cosmopolitan 4.x toolchain (`lib.cosmoStdenv`; also wires `pkgs.pkgsCross.cosmo` as a first-class cross target inside `windowsPkgs`). |
| `<pkg>/` directories | Per-package flakes — one repo per tool. See [unpins.org/packages](https://unpins.org/packages.html) for the current catalog. |
| `action-build/` | Reusable GitHub Actions workflows that build, verify, and release each flake. |
| `website/` | Site source (`unpins.org`). |
| `playground/` | Work-in-progress packages, not consumed by `unpin` or the website. Each entry is either blocked on an upstream issue (bash, coreutils, git) or a recipe/POC kept around for reference (dash, static-gtk2-recipe). |

The local `/home/<user>/projetos/unpins/` directory is a **view** of those independent repos — it is not itself a git repo. Commit and push in the package's own directory.

## `mkStandaloneFlake`

Every package flake calls `unpins-lib.lib.mkStandaloneFlake { name = "<pkg>"; ... }`. The template emits:

```
packages.<system>.default                        — native pkgsStatic build
packages.aarch64-darwin."darwin-x86_64"           — cross within darwin
packages.x86_64-linux."windows-x86_64"            — mingw or cosmo cross from linux
apps.<system>.default                             — `nix run` entry
manifest                                          — read by action-build for CI config
```

### Parameters

| Argument | Default | Purpose |
| -------- | ------- | ------- |
| `self` | required | The consumer flake's `self`. |
| `name` | required | Package name (user-facing id / repo slug / binary). |
| `pkgsAttr` | `name` | nixpkgs attribute name when it differs from `name` (e.g. `gnused`, `gnugrep`, `gnumake`). |
| `build` | `null` | Explicit native builder `pkgs -> drv`. When `null`, falls back to `pkgs.pkgsStatic.<pkgsAttr>`. |
| `windowsBuild` | `null` | Explicit Windows builder (mingw, cosmo, or anything that returns a `pkgs -> drv`). For cosmo the convention is `windowsBuild = import ./cosmo.nix { inherit unpins-lib; }` where the sidecar invokes `lib.cosmoStaticCross pkgs`. When `null`, dispatch falls back to the `windowsCosmo` / `windows` flags below. |
| `binName` | `name` | Override for `apps.default` when the binary's name differs from the package name. |
| `nativeBuild` | `true` | Set to `false` for Windows-only packages (no native build is emitted). |
| `linuxOnly` | `false` | Suppresses every Darwin attr from `packages.<sys>` (kmod, util-linux, shadow, procps-ng — Linux-kernel-only tools). |
| `windows` | `false` | Set to `true` to enable the plain mingw cross path: `(mingwStaticCross pkgs).<pkgsAttr>`. (`windowsBuild` not null also enables it.) |
| `windowsCosmo` | `false` | Legacy shortcut for `windowsBuild = pkgs: (cosmoStaticCross pkgs).<pkgsAttr>` (no consumer customization). The catalog now uses the `./cosmo.nix` sidecar pattern via `windowsBuild` for symmetry with mingw; this flag stays for one-liner cases. See [platforms/cosmocc.md](platforms/cosmocc.md). |
| `package_data` | `true` | Tells action-build to also publish `result/share` as a `.tar.zst`. |
| `bootstrap_naming` | `false` | Used by `unpin/` itself for the bootstrap asset name convention. |
| `own_software` | `false` | Marks `unpin/` itself (and any future first-party tool) — affects release notes. |

### Output post-processing

The template normalizes single- vs multi-output drvs into a single `result/` symlink so action-build's verifier finds the binary at `result/bin/<pkg>` regardless of the upstream output structure. It also runs `dropSharedLibs` to remove stray `.so`/`.dylib`/`.dll`/`.dll.a`/`.la` artifacts from any output that fell back to non-static dependencies (a no-op for `pkgsStatic` outputs, which already produce only `.a`).

## Where per-target quirks live

Per-binary quirks are **inline in the consumer flake**, not in `nix-lib`:

- **native + mingw**: `build = pkgs: ...` / `windowsBuild = pkgs: ...` closures inside `flake.nix`.
- **cosmocc**: a `./cosmo.nix` sidecar file invoked via `windowsBuild = import ./cosmo.nix { inherit unpins-lib; }`. The sidecar receives `pkgs` and calls `unpins-lib.lib.cosmoStaticCross pkgs` to construct the cosmo cross set. Lives in its own file because cosmo recipes typically need `cs = import "${unpins-lib.outPath}/cosmocc.nix" { pkgs = pkgs.buildPackages; }` for `apelink` access plus a non-trivial postFixup.

For substantial multi-step recipes (multicall via post-link `ld -r`, big patch sets, ...), the consumer flake calls `import ./multicall.nix { lib = pkgs.lib // unpins-lib.lib; } pkgs` from a sibling file.

`nix-lib` retains three overlay-fragment directories for **transitive lib deps** — quirks that one consumer would otherwise have to apply to every other consumer's transitive closure:

```
nix-lib/native-overlay/<lib>.nix      # cross-darwin / pkgsStatic-linux lib fixes (dav1d, libevent, libopus)
nix-lib/mingw-overlay/<lib>.nix       # spliced into mingwStaticCross via overlay (libidn2, libpsl, ncurses)
nix-lib/cosmo/<lib>.nix               # spliced into cosmoStaticCross (libedit, libevent, ncurses, openssl)
```

Each is auto-discovered via `readDir`. Add a new file here only when the fix is consumed by ≥ 2 packages transitively (e.g. ffmpeg + a future consumer both wanting a static `dav1d`); a one-binary quirk belongs in that binary's flake.

When an overlay fragment propagates a *modified* dep to a consumer, reference it as `self.X`, **not** `super.X` — `super.X` is the pre-overlay vanilla derivation, so using it spawns a second phantom copy of the lib alongside the fixed one and the consumer may link the wrong one (see [static-linking.md](static-linking.md#propagation--outputs)).

`mingw-overlay` entries are stitched into `mingwStaticCross pkgs` as overlay fragments, so curl, ffmpeg, etc. transparently see the fixed `libidn2` / `libpsl` / `ncurses`. The `cosmo/` directory has the analogous role for `cosmoStaticCross`.

## `mingwStaticCross pkgs`

A helper in `nix-lib` that returns `pkgsCross.mingwW64` plus an overlay that:

1. Wraps the stdenv with `makeStaticLibraries` — injects `--enable-static --disable-shared` for autotools, `-DBUILD_SHARED_LIBS=OFF` for cmake, `-Ddefault_library=static` for meson into every `mkDerivation`.
2. Sets `stdenv.hostPlatform.isStatic = true`. A small lie at the platform-attr level (not a re-instantiation) — upstream recipes key off `isStatic` directly (`zlib`'s `shared ? !isStatic`, etc.) and produce `.a`-only outputs.
3. Stitches in every `nix-lib/mingw-overlay/<lib>.nix` entry as part of the overlay.

`pkgsCross.mingwW64.pkgsStatic` is **not** used because it re-instantiates nixpkgs with `crossSystem.isStatic = true` → cross GCC rebuilds against modified `windows.mingw_w64`/`mcfgthread` configureFlags → ~30 min toolchain rebuild for byte-identical output.

## `mingwStaticBinary`

Companion helper that finalizes a mingw binary for shipping. Adds the piece the per-library adapter can't: libtool-aware `LDFLAGS=-all-static` at make time, so the *final* link resolves to `.a` only (without it, libtool picks `.dll.a` and the DLL-link hook copies the matching `.dll` next to the binary).

Used by consumer flakes (e.g. `curl`) that need fine control over `staticDeps`, `extraInputs`, `extraConfigureFlags`, and `extraCFlags` (for `*_STATICLIB` defines).

## `nix-lib` scope

Every package flake calls `mkStandaloneFlake`. Beyond that, packages tap into `nix-lib` at different depths:

- **Pure default** — `sed`, `jq`: just rely on the `pkgs.pkgsStatic.<pkgsAttr>` fallback; no `build` / `windowsBuild` needed if the upstream attr cross-builds clean.
- **Inline overrides** — `htop`, `tmux`, `coreutils`, `tar`, `xz`, `nano`, …: `pkgsStatic` works but needs small overrides on darwin or mingw. The override lives inline in the consumer's `build` / `windowsBuild` closure.
- **`mingwStaticBinary` + the mingw overlay chain** — `curl` (libpsl/libidn2/libunistring chain), `ffmpeg` (codec libs). Substantial static-dep chains that benefit from the full toolbox; the transitive lib quirks sit in `nix-lib/mingw-overlay/`.
- **Custom `build` / `windowsBuild`** — `vim`, `gvim`, `file`: don't fit `pkgsStatic.<name>` at all (Vim's `Make_ming.mak`, gvim's GTK2 stack, file's libgnurx rebuild). The consumer flake supplies the build directly.

**Rule:** add a file to `nix-lib/{native,mingw}-overlay/` or `nix-lib/cosmo/` only when the fix is for a transitive **library** dep that ≥ 2 binaries pull in. Per-binary quirks belong inline in the consumer flake — even if it's a 30-line `windowsBuild` closure.

## Verifying refactors

After touching `nix-lib`, drv-hash diff each consumer flake against the cached version to confirm a byte-equivalent refactor:

```bash
cd <pkg>
nix eval --override-input unpins-lib path:../nix-lib \
  .#packages.<system>.<output>.drvPath
```

A mismatch means the refactor changed the output. State a reason (intentional behavior change, upstream version bump, etc.) before merging.
