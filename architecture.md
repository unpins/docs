# Architecture

## What ships

Each `unpins/<pkg>` repository ships **one executable per OS**. Runtime data (magic databases, runtime trees, completions) and man pages are **embedded inside the binary** (see [runtime-data.md](runtime-data.md) and [embedded-man.md](embedded-man.md)); a `.tar.zst` companion archive (`package_data`) is a rare opt-in fallback for data that can't be embedded. The binary must run on a stock system with only what the OS itself provides — see [dynamic-link-policy.md](dynamic-link-policy.md).

## Workspace layout

Top-level directories are **independent git repositories**:

| Path | Purpose |
| ---- | ------- |
| `unpin/` | The Rust CLI installer (`unpin install <pkg>`). |
| `nix-lib/` | Shared Nix helpers: `mkStandaloneFlake` template, the unpin-llvm engine ([below](#the-unpin-llvm-engine)) with its multicall/mega-fold machinery, cross-overlay fragments (`native-overlay/`, `mingw-overlay/`, `cosmo/`) for transitive lib deps, and the bundled Cosmopolitan 4.x toolchain (`lib.cosmoStdenv`; also wires `pkgs.pkgsCross.cosmo` as a first-class cross target inside `windowsPkgs`). |
| `<pkg>/` directories | Per-package flakes — one repo per tool. See [unpins.org/packages](https://unpins.org/packages.html) for the current catalog. |
| `action-build/` | Reusable GitHub Actions workflows that build, verify, and release each flake. |
| `website/` | Site source (`unpins.org`). |
| `playground/` | Work-in-progress packages and reference POCs, not consumed by `unpin` or the website — e.g. `git` (multicall WIP), `static-gtk2-recipe`, the engine/toolchain spikes (`llvm`, `unpin-stdenv`, `mega-multicall`, …). Packages graduate to a top-level repo when they ship (bash, coreutils, dash all did). |

The local `/home/<user>/projetos/unpins/` directory is a **view** of those independent repos — it is not itself a git repo. Commit and push in the package's own directory.

## `mkStandaloneFlake`

Every package flake calls `unpins-lib.lib.mkStandaloneFlake { name = "<pkg>"; ... }`. The template emits five top-level outputs — `packages`, `apps`, `cross`, `manifest`, `unpinRecipe`:

```
packages.<system>.default                        — native static build (per native system)
packages.aarch64-darwin."darwin-x86_64"          — cross to Intel, within darwin
packages.x86_64-linux."linux-i686"               — cross, ditto "linux-ppc64le", "linux-riscv64"
packages.aarch64-linux."linux-armv7l"            — cross from the arm runner
packages.x86_64-linux."windows-x86_64"           — mingw or cosmo cross from linux (when enabled)
apps.<system>.default                            — `nix run` entry
cross.<arch>                                     — flat, x86_64-linux-hosted cross for every extra
                                                   linux arch (aarch64, armv7l, i686, …, m68k,
                                                   loongarch64, s390x, …) + x86_64-v2/v3/v4;
                                                   local checks only, invisible to CI
manifest                                         — read by action-build for CI config (smoke,
                                                   smoke_pattern, applets_by_target, …)
unpinRecipe                                      — the call's own args, re-consumable by
                                                   lib.mkMegaFromRecipes (the unpinbox fold)
```

CI builds its matrix **only** from `packages.<system>.*` — `cross.*` and anything else never reach a runner.

### Parameters

The argument set is closed — an unknown top-level argument (or an unknown key inside `optimize` / `multicall` / `multicallCosmo`) is an eval error, so this table can be trusted as exhaustive.

**Identity and builders:**

| Argument | Default | Purpose |
| -------- | ------- | ------- |
| `self` | required | The consumer flake's `self`. |
| `name` | required | Package name (user-facing id / repo slug / binary). |
| `pkgsAttr` | `name` | nixpkgs attribute name when it differs from `name` (e.g. `gnused`, `gnugrep`, `gnumake`). |
| `description` | `null` | Overrides the artifact's description (website copy). |
| `license` | `null` | Pin the effective license when upstream `meta.license` is missing or a noisy multi-license list (ffmpeg, python). |
| `build` | `null` | Explicit native builder `pkgs -> drv`. When `null`, falls back to `nativeFixes.<pkgsAttr>` if one exists, else `pkgs.pkgsStatic.<pkgsAttr>`. |
| `windowsBuild` | `null` | Explicit Windows builder (mingw, cosmo, or anything that returns a `pkgs -> drv`). For cosmo the convention is `windowsBuild = import ./cosmo.nix { inherit unpins-lib; }` where the sidecar invokes `lib.cosmoStaticCross pkgs` (extra args beyond `unpins-lib` are fine). When `null`, dispatch falls back to the `windowsCosmo` / `windows` flags below. |
| `binName` | `name` | Override for `apps.default` when the binary's name differs from the package name. |

**Target selection:**

| Argument | Default | Purpose |
| -------- | ------- | ------- |
| `nativeBuild` | `true` | Set to `false` for Windows-only packages (no native build is emitted). |
| `linuxOnly` | `false` | Suppresses every Darwin attr from `packages.<sys>` (kmod, util-linux, shadow, procps-ng — Linux-kernel-only tools). |
| `windows` | `false` | Set to `true` to enable the plain mingw cross path: `(mingwStaticCross pkgs).<pkgsAttr>`. (`windowsBuild` not null also enables it.) |
| `windowsCosmo` | `false` | Shortcut for `windowsBuild = pkgs: (cosmoStaticCross pkgs).<pkgsAttr>` (no consumer customization — `tree` is the one user). Packages needing quirks use the `./cosmo.nix` sidecar via `windowsBuild` instead. See [platforms/cosmocc.md](platforms/cosmocc.md). |

**Engine and multicall** (see [the engine section below](#the-unpin-llvm-engine)):

| Argument | Default | Purpose |
| -------- | ------- | ------- |
| `engine` | `"default"` | `"unpin-llvm"` builds the whole static closure with the project's clang/LLVM bitcode toolchain instead of nixpkgs' gcc stdenv — the catalog default in practice (everything but the Rust packages). Applies to linux (native + every cross arch) and native darwin. |
| `multicall` | `null` | Declares the package's programs for the engine self-fold: `{ programs = [ { name; aliases?; objs?; … } ]; defaultProgram?; depArchives?; windows?; windowsTable?; … }`. One binary dispatches every declared program; also emits the bitcode `multicallModule` the mega fold consumes. `windowsTable` is what a **bespoke** `windowsBuild` folds, as a `lib.multicallTable` — nothing in eval can look inside that build, so the flake declares it and CI checks the `.exe` against it. See [multicall.md](multicall.md). |
| `multicallCosmo` | `null` | Cosmo-side multicall spec for packages whose Windows build is cosmo (bash, coreutils). Mutually exclusive with the mingw module path. |
| `optimize` | `{ }` | `{ lto?, opt?, ssp?, gc? }` knobs for the **default** (non-engine) stdenv. Under `engine = "unpin-llvm"` the `lto`/`gc` knobs are silent no-ops — the engine toolchain owns those decisions. |
| `runtimeEmbed` | `null` | `{ native?, windows? }` hooks for embedding a runtime tree in the binary's self-EOF ZIP (see [runtime-data.md](runtime-data.md)). |

**Artifact contents and verification:**

| Argument | Default | Purpose |
| -------- | ------- | ------- |
| `embedMan` | `true` | Embed man pages as `unpin/man/*` in the binary's ZIP (see [embedded-metadata.md](embedded-metadata.md)). |
| `winManRoot` | `null` | Explicit curated man tree for the Windows artifact, when the cross build ships none of its own. |
| `removeReferences` | `[ ]` | Scrub dead `/nix/store` references from the artifact (opt-in). |
| `smoke` | `null` | Argv list for CI's smoke run (e.g. `[ "--version" ]`). |
| `smokePattern` | `null` | Regex the smoke output must match. |
| `smokeWindows` | `true` | Set `false` for a GUI-subsystem `.exe` that has no console — the Windows smoke would hang. |
| `darwinAllowPrivateFrameworks` | `[ ]` | Extra frameworks the darwin portability verifier accepts for this package (fastfetch). |
| `package_data` | `false` | Off by default — embedding runtime data in the binary is the norm. Set `true` only for data that genuinely can't be embedded (today: nmap alone); action-build then publishes `result/share` as a `.tar.zst`. See [runtime-data.md](runtime-data.md). |
| `own_software` | `false` | Marks `unpin/` itself (and any future first-party tool) — affects tag format and release notes. |
| `dnsFallback` | `false` | Set to `true` for a package that resolves hostnames (curl, rsync, links, …). Links a `getaddrinfo` interposer that can reach a public resolver on a host that has none — Android ships no `/etc/resolv.conf`, so musl falls back to `127.0.0.1:53` and every lookup fails. **Opt-in at runtime too**: dormant unless the user sets `UNPIN_DNS` or a `dns =` line in unpin's config, which the shim reads itself, so every binary carrying it honours the setting with no env var. It never second-guesses a working resolver (an authoritative `NXDOMAIN` is respected). For a catalog package it applies on **linux-static only**; the darwin and Windows interposition paths exist but are reached only by `unpin`'s own bespoke wiring. Unsupported for Rust crates — `mkRustCrate` asserts on it. |

**Which package set a `pkgs:` option receives.** `build`, `runtimeEmbed.*` and `multicall.{depArchives,runtimeDataRoot}` are all functions of a package set, and they are handed the set the build itself used — one binding (`engPkgs`), so the build and the manifests cannot drift apart:

| Option | Receives |
| ------ | -------- |
| `build`, `runtimeEmbed.native` | The target's nixpkgs root with `pkgsStatic` swapped to the engine set. |
| `multicall.depArchives`, `multicall.runtimeDataRoot` | The same set for the native/darwin module; `mingwStaticCross` of the windows engine root for the `.exe` module (there `stdenv.hostPlatform` IS Windows); `cosmoStaticCross` for a cosmo module. |
| `runtimeEmbed.windows` | The linux root that hosts the mingw cross, with the engine sub-scope swapped — **not** the mingw set. |

Two rules follow. An **archive** you name (`depArchives`) must come from the set you were handed: the base set does not fail, it silently returns a *second*, unfixed build of the dep, and the package links an archive cut from a closure its own build never saw (vorbis-tools linked a `libpulsecommon.a` from a closure carrying two libpulseaudio, two dbus and two libx11, and its `.exe` had a linux-musl archive on the link line). A **tool** you run to stage files (`runtimeEmbed.*`, `runtimeDataRoot`) comes through `pkgs.buildPackages.<tool>`: on every cross target the root's bare `pkgs.<tool>` is cross-compiled, and handing an embed callback the mingw set put a mingw coreutils and bash into biber's closure.

**Sharing hooks** (`sharedPkgs`, `sharedToolchain`, `sharedEnginePkgsStatic`, `sharedCrossPkgs`) let an umbrella caller (the unpinbox mega) inject already-instantiated package sets so N packages don't each re-instantiate nixpkgs; a normal package flake never sets them.

### Output post-processing

The template normalizes single- vs multi-output drvs into a single `result/` symlink so action-build's verifier finds the binary at `result/bin/<pkg>` regardless of the upstream output structure. It also runs `dropSharedLibs` to remove stray `.so`/`.dylib`/`.dll`/`.dll.a`/`.la` artifacts from any output that fell back to non-static dependencies (a no-op for `pkgsStatic` outputs, which already produce only `.a`).

## The unpin-llvm engine

`engine = "unpin-llvm"` swaps the build toolchain: instead of nixpkgs' gcc-based static stdenv, the package **and its whole static dependency closure** compile with the project's clang/LLVM toolchain to LLVM bitcode, linked by lld. This is the catalog default in practice. Off it are the four Rust packages (`cfonts`, `fish`, `rsvg-convert`, `unpin` — the first goes through `mkRustCrate`, not `mkStandaloneFlake`) and one C package, `busybox`, because kbuild pipes every `-MD` depfile through `fixdep`, which reopens headers the engine serves from a virtual root with no on-disk existence (its flake says so at length). `xvfb` and `xvnc` set no `engine` and are on it all the same on linux: their bespoke `build` calls `lib.enginePkgsStaticFor` directly (their Windows builds are cosmo). Measure adoption from `.drv` closures (`nix-store -qR … | grep unpin-llvm`), never by grepping flakes for `engine`.

How it's wired (all inside `mkStandaloneFlake`):

- **Set-wide, not per-package.** The engine replaces `pkgs.pkgsStatic` itself (`enginePkgsStaticFor`), so a `build = pkgs: pkgs.pkgsStatic.<x>.override { … }` closure works unchanged — the same expression just resolves against the engine set. A consumer flake never mentions the engine beyond the one `engine` argument.
- **Engine dep fixes ride the set too.** A transitive dep that breaks under the engine is fixed once, in `nix-lib/native-overlay/<dep>.nix` declaring `{ autoWire = "musl" | "static"; apply = pkgs: drv; }`, and folded into the engine `pkgsStatic` for every consumer whose host matches the gate (musl hosts, or every static host incl. darwin) — 25 of the 58 files there today (`libx11`/`libxt`'s `RAWCPP`, `libjpeg-turbo` without LTO, …). A flake must not re-apply one: the copy is at best an idempotent duplicate that drifts. Eight flakes carried the `RAWCPP` override by hand until it moved into nix-lib.
- **`malloc` is pinned on every full link.** musl's `malloc` is a weak alias, and full LTO against the bitcode libc can drop its definition while the calls to it survive: `undefined symbol: malloc`, with `calloc` defined in the same `.lto.o`. It is not only a failed link — a configure probe that links a program hits it and the feature turns off in silence (pango's `cairo-ft` probe → FontConfig off). The engine's `ld.lld` (`engineLd`) appends `-u malloc` to every non-relocatable link on a Linux engine target, covering both the linker the driver finds through `-B` and one a build execs directly, and never to a `-r` link, which must not pull libc members. **A flake never adds `-u malloc` itself.** Darwin and mingw link no bitcode musl and are untouched.
- **The build machine's compiler is pinned by property.** A hook on the engine stdenv (`unpin-build-cc`) fills `CC_FOR_BUILD` / `CXX_FOR_BUILD` / `BUILD_CC` with the real builder's compiler — with `:=`, so a `depsBuildBuild` cc-wrapper or a package's own `preConfigure` still wins — and after configure asserts that meson's own `Build machine cpu family:` matches the builder known at eval time. It is gated on the HOST cpu, because meson only ever *demotes* the builder's machine (x86_64 → x86 under `__i386__`, aarch64 → arm under `__arm__`), so only the i686 and armv7l targets can be mislabelled. armv7l dies loudly (`Can not run test applications in this cross environment`); i686 was silently wrong for months. The assert lives in the drv, so a cached output is necessarily one that passed. There is no per-package list to join any more: the old `mesonBuildCcPkgs` is gone. The hook rides the **stdenv** derivation (`extraNativeBuildInputs`), so look for `unpin-build-cc` in `stdenv-*.drv`, not in the package's own `.drv`.
- **Scope**: native linux, every linux cross arch, and native darwin. The mingw cross joins when `multicall.windows = true` (and `multicallCosmo` is unset) — that routes the Windows build through the engine adapter and self-folds the `.exe`'s dispatcher too.
- **Multicall self-fold.** With `multicall = { programs = [ … ]; }`, a package that upstream ships as several executables becomes one binary with the shared dispatcher ([multicall.md](multicall.md)) — no hand-written fold recipe. Each program's `main` is renamed at the bitcode level, and the build emits a `module` output (`module.bc` + a `module_native.a` sidecar for asm that can't be bitcode) exposed as `passthru.multicallModule`.
- **Mega fold.** Those modules are what `lib.mkMegaMulticall` / `lib.mkMegaFromRecipes` consume to fold *many packages* into one busybox-style binary — the `unpinbox` flake. Dep archives dedupe by store path, which is only sound because every module builds against one pinned toolchain/libc (`follows` on a single `unpins-lib`).
- **`optimize.lto` / `optimize.gc` are no-ops under the engine** — it owns those decisions. They only affect the non-engine (`"default"`) stdenv.

## Where per-target quirks live

Per-binary quirks are **inline in the consumer flake**, not in `nix-lib`:

- **native + mingw**: `build = pkgs: ...` / `windowsBuild = pkgs: ...` closures inside `flake.nix`.
- **cosmocc**: a `./cosmo.nix` sidecar file invoked via `windowsBuild = import ./cosmo.nix { inherit unpins-lib; }`. The sidecar receives `pkgs` and calls `unpins-lib.lib.cosmoStaticCross pkgs` to construct the cosmo cross set. Lives in its own file because cosmo recipes typically need `cs = import "${unpins-lib.outPath}/cosmocc.nix" { pkgs = pkgs.buildPackages; }` for `apelink` access plus a non-trivial postFixup.

Multicall packages declare their programs via the `multicall = { … }` argument — the engine folds them ([see above](#the-unpin-llvm-engine)). The old hand-written `./multicall.nix` sibling files are retired; the ones that remain (`unzip`, `usbutils`, `zip`, plus `diffutils/windows.nix`, `e2fsprogs`+`findutils`+`moreutils`'s `cosmo.nix`, `procps-ng/portable.nix`) are Windows-only fallbacks for folds the engine's bitcode path can't do there. Each renders its table with `lib.multicallTable` and declares the same value as `multicall.windowsTable`.

`nix-lib` retains three directories of **transitive lib-dep fixes** — quirks that one consumer would otherwise have to re-apply to every other consumer's transitive closure. All three are auto-discovered via `readDir`:

```
nix-lib/native-overlay/<lib>.nix      # native (pkgsStatic-linux + cross-darwin) — e.g. dav1d, libevent, libopus, svt-av1
nix-lib/mingw-overlay/<lib>.nix       # mingw cross — e.g. libidn2, libpsl, ncurses
nix-lib/cosmo/<lib>.nix               # cosmo cross — e.g. libedit, libevent, ncurses, openssl
```

**How a consumer reaches each — and where it trips people up.** The native side and the cross side are wired *differently*; a fix you "can't find" is usually one you're reaching for the wrong way:

- **`native-overlay/`** is **mostly not an overlay** despite the directory name. Each file is exposed as `unpins-lib.lib.nativeFixes.<lib>` (`pkgs -> drv`). A plain fix is one the consumer **calls explicitly** and threads in — nothing rewrites your transitive closure for it. The exception is a file declaring `autoWire` (25 of 58), which *is* folded into the engine `pkgsStatic` for every consumer ([see the engine section](#the-unpin-llvm-engine)); calling one of those by hand only adds a duplicate. A plain fix looks like:

  ```nix
  build = pkgs: let p = pkgs.pkgsStatic; in
    p.<pkg>.override { <lib> = unpins-lib.lib.nativeFixes.<lib> p; };   # cf. tmux's libevent, ffmpeg's codec libs
  ```

  The one automatic use: when you supply no `build` closure, `mkStandaloneFlake` resolves the package's *own* build to `nativeFixes.<name>` if a `native-overlay/<name>.nix` exists, else `pkgs.pkgsStatic.<name>` (flake.nix `rawBuild`).

- **`mingw-overlay/` and `cosmo/`** *are* real overlays, stitched into `mingwStaticCross pkgs` and the cosmo cross set respectively. Build **through that set** and the fixed `libidn2` / `libpsl` / `ncurses` / … are already in place transitively — curl, ffmpeg, etc. get them for free. Bypassing the set (raw `pkgsCross.mingwW64.<lib>`) loses the fix.

Add a new file to any of the three only when the fix is consumed by **≥ 2 packages** transitively (e.g. ffmpeg + a future consumer both wanting a static `dav1d`); a one-binary quirk belongs inline in that binary's flake.

When you *write* a `mingw-overlay` / `cosmo` fragment that propagates a modified dep, reference it as `self.X`, **not** `super.X` — `super.X` is the pre-overlay vanilla derivation, so using it spawns a second phantom copy of the lib alongside the fixed one and the consumer may link the wrong one (see [static-linking.md](static-linking.md#propagation--outputs)).

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
