# macOS / darwin

unpins ships darwin binaries for **both** `aarch64-darwin` (Apple Silicon) and `x86_64-darwin` (Intel). Apple Silicon runners are the canonical CI host — they cross-build x86_64 within darwin via `pkgsCross.x86_64-darwin`.

## The single-Mac CI pattern

```
packages.aarch64-darwin.default                  # native aarch64
packages.aarch64-darwin."darwin-x86_64"          # cross to Intel, on the same runner
```

`mkStandaloneFlake` wires both automatically. The cross-within-darwin path is solid; cross-from-linux is broken upstream — see the dead-ends section below.

## `pkgsStatic` on darwin: how it actually behaves

`pkgsStatic` on darwin does **not** inject a global `-static` LDFLAG. Reading `pkgs/stdenv/adapters.nix`:

- `makeStatic` on darwin skips `makeStaticBinaries` entirely.
- `makeStaticDarwin` adds `-static-libgcc` for GNU compilers (clang skipped — clang doesn't need it).
- `makeStaticLibraries` passes `--enable-static --disable-shared` to configures.

The autoconf-standard meaning of `--enable-static` is "produce a static library archive". It should **not** add `-static` to the linker.

When `pkgsStatic.<pkg>` on darwin fails configure with `checking for access... no` and `NaN, isgreater() and isgreaterequal()` errors, the cause is **almost certainly inside the package's own `configure.ac`**, not nixpkgs.

### Worked example: htop

htop's `configure.ac` doesn't use libtool and handles `--enable-static` **non-standardly** — it sets `CFLAGS=-static LDFLAGS=-static`. nixpkgs' adapter passes the flag assuming standard meaning; htop reinterprets, and the link probes against libSystem fail (libSystem.a does not exist on darwin).

Diagnosis: dump `config.log`, look at the final `CFLAGS=` / `LDFLAGS=` block. If `-static` is there but not in `NIX_LDFLAGS` / `NIX_CFLAGS_LINK`, the package's own configure added it.

The darwin branch lives inline in `htop/flake.nix`'s `build` closure (the consumer's own flake also handles linux's `lm_sensors`); the `--enable-static` filter is now a generic `lib.filterEnableStaticOnDarwin` helper applied automatically by `mkStandaloneFlake`, so most darwin consumers don't need a manual filter. Manual sketch of the shape:

```nix
build = pkgs:
  let p = pkgs.pkgsStatic; in
  if p.stdenv.hostPlatform.isDarwin then
    p.htop.overrideAttrs (old: {
      configureFlags = pkgs.lib.filter
        (f: f != "--enable-static" && f != "--disable-shared")
        (old.configureFlags or [ ]);
    })
  else p.htop;
```

No `ncurses` override is needed: `pkgsStatic.ncurses` on darwin already passes `--without-shared` in its default `configureFlags` and ships only `.a`.

### Other forms of the same trap

- `tmux`'s `configure.ac` on darwin passes `-static` globally → libSystem link probe fails. Fall back to non-static tmux with deps' shared libs pruned (`withDepsSharedPruned` helper); runtime closure ends up libSystem-only either way.
- The general principle: when an autotools probe complains about libSystem at link time, the package is misinterpreting `--enable-static`. Filter the flag from `configureFlags`.

## Why not overlays for per-package fixes

`pkgs.appendOverlays` (or `pkgsStatic.appendOverlays`) reinstantiates the nixpkgs set. Hash changes propagate to every subset, including `pkgsBuildHost.stdenv`. On darwin this cascades into `compiler-rt-libc-static-arm64-apple-darwin` being rebuilt from source, which drags `python3`/`ninja`/`cmake` because `cache.nixos.org` only builds pkgsStatic-linux on Hydra — pkgsStatic-darwin toolchain has near-zero cache coverage.

Real numbers measured during the htop investigation:

| | hash | cache |
| - | ---- | ----- |
| `pkgs.stdenv` aarch64-darwin | `n4dcsy…-stdenv-darwin.drv` | HTTP 200 |
| `pkgsStatic.pkgsBuildHost.stdenv` (no overlay) | identical | HTTP 200 |
| `pkgsStatic.pkgsBuildHost.stdenv` after **any** `appendOverlays` | different | 404 |
| `compiler-rt-libc-static-arm64-apple-darwin` after overlay | — | 404 |
| Same, no overlay | — | HTTP 200 |

`pkg.override { dep = newDep; }` and `drv.overrideAttrs (…)` produce a new drv whose **own** input hash differs (it rebuilds), but the build inputs (`stdenv`, `cc`, `bintools`, …) it references stay the cached ones — only the package itself rebuilds. That keeps darwin CI in the 5-10 min range instead of 30-60.

**Rule:** fixes for `pkgsStatic-darwin` packages live inline in the consumer flake's `build = pkgs: ...` closure, each returning `drv.override { … }` or `drv.overrideAttrs (…)`. Adding a package = writing a `build` closure inside `mkStandaloneFlake`.

**Symptom that you've slipped back into the overlay trap:** darwin CI starts building `python3-3.13.x.drv`, `ninja-*.drv`, `compiler-rt-libc-static-…drv` in sequence (10+ min just for python). Audit the path that was changed; you've probably introduced an `appendOverlays` somewhere.

## Rust packages: the libiconv catch

`pkgsCross.x86_64-darwin.rustPlatform` (note: plain, **not** `pkgsCross.x86_64-darwin.pkgsStatic.rustPlatform`) is what we use for `unpin`'s darwin-x86_64 cross within darwin. Plain `cross.rustPlatform` keeps `/nix/store`-freedom because Rust deps are statically linked into the rustc output and darwin's libSystem stays dynamic regardless.

Why not pkgsStatic for the whole build:

1. The `pkgsStatic` view triggers a rebuild of the cross cctools/ld64 toolchain in its "static" variant, which fails on `xar-static-arm64-apple-darwin` (`Cannot build without libxml2` — the cross-static libxml2 chain is broken upstream).
2. Plain cross still satisfies the policy because Rust does the static link itself.

**The libiconv catch** is not Rust-specific — it bites any darwin build that references iconv (rustc appends `-liconv` by default; C objects like libxml2.a's `encoding.o` call `iconv_open`). macOS keeps iconv in a standalone `libiconv` (musl/glibc fold it into libc, so Linux needs nothing), and the allow-list permits only libSystem + libobjc + Frameworks. There are **two distinct traps**:

1. **Target link (every darwin build).** Whatever references iconv needs a libiconv to resolve against, and it must be the **static** one — the default cross stdenv resolves `-liconv` to nixpkgs' libiconv *dylib*, so the binary carries `LC_LOAD_DYLIB /usr/lib/libiconv.2.dylib`, which the allow-list rejects. Prepend `pkgsStatic.libiconv` (a leaf — it doesn't pull the broken cctools-static cascade) so the linker sees the `.a` first and emits no load command, and append a bare `-liconv` after the archive that references it.

2. **Build-host link (cross only).** cargo/cmake build scripts and proc-macro dylibs are compiled for the **build host**, and rustc appends `-liconv` to *their* link too — against the build cc-wrapper's salted `NIX_LDFLAGS_<buildSalt>` (e.g. `NIX_LDFLAGS_arm64_apple_darwin`), which has no default path for it, so the build dies with `ld: library not found for -liconv` *during the build* (not a gate failure). Hand that wrapper a `-L` to the **build-arch** libiconv. This is **cross-only**: on a native build the build salt equals the target salt, so the same `-L` would instead pull a dynamic libiconv into the final binary and trip trap 1. (`depsBuildBuild = [ libiconv ]` does *not* fix it — that surfaces only the `-dev` output, not the `out` that holds the dylib; use `lib.getLib`.)

   Note: CI builds `darwin-x86_64` as an **arm64→x86_64 cross** (action-build has no Intel macOS runner; see `runnerMap`), so a native build on an Intel Mac will *not* reproduce this trap — only the CI cross or the local `./build-aarch64-darwin` Intel→arm64 check will.

**Both are handled automatically** for any `mkStandaloneFlake` package by `nix-lib`'s `withDarwinIconv` (folded into the `core` pipeline beside `filterEnableStaticOnDarwin`): it adds `pkgsStatic.libiconv` + a bare `-liconv` to every darwin build, and the cross-only build-host `-L`. So a package whose iconv need is on its **own final drv** needs *nothing* — don't re-add it.

**You still wire it by hand when the iconv reference is not on the final mkStandaloneFlake drv:**

- **A custom cross derivation** assembled outside the `stripped` pipeline — e.g. `unpin`/`unpin-readme`'s `darwinX86Unpin` (a hand-built `pkgsCross.x86_64-darwin.rustPlatform` drv). Both traps apply; do both by hand:

  ```nix
  darwinX86Unpin =
    let cross = nixpkgsFor.aarch64-darwin.pkgsCross.x86_64-darwin; in
    (mkUnpin { rustPlatform = cross.rustPlatform; }).overrideAttrs (old: {
      buildInputs = [ cross.pkgsStatic.libiconv ] ++ (old.buildInputs or [ ]);   # trap 1
      NIX_LDFLAGS_arm64_apple_darwin = "-L${cross.buildPackages.libiconv}/lib";   # trap 2
    });
  ```

- **A dependency's internal static link** — e.g. `fastfetch` links libxml2.a *through imagemagick*; the `-liconv` belongs on the **imagemagick** overlay, which `withDarwinIconv` (on the fastfetch drv) never reaches.

- **A libiconv whose `.a` lives in the `dev` output** — `binutils` folds `pkgsStatic.libiconv`'s archive straight into a manual link line and must probe `getDev`/`getLib`/`out` for it, because the bare `-liconv` (resolved via the `out/lib` `-L`) won't find it there.

**Previous failed approach** (don't revive): `install_name_tool -change` retargeting to `/usr/lib/libiconv.2.dylib`. The dylib is in the dyld shared cache on every macOS, but action-build rejects it — staticize instead.

## C++ apps: static-link libc++

The allow-list permits `libSystem` + Frameworks + `libobjc` — **not** `/usr/lib/libc++.1.dylib`. A C++ binary built with `clang++` links libc++ dynamically by default and gets rejected. Static-link the C++ runtime into the final link:

```nix
extraLinkFlags = "-nostdlib++ ${sp.libcxx}/lib/libc++.a ${sp.libcxx}/lib/libc++abi.a";
```

`-nostdlib++` suppresses the implicit `-lc++`, then the two `.a`s supply it statically. (Linux `pkgsStatic` already links the musl libc++/libstdc++ statically, so it needs no extra flags — this is darwin-only.) Cases: x265's CLI, srt's multicall, librist (via [../multicall.md](../multicall.md)'s `extraLinkFlags`). `otool -L` should then show only `libSystem.B.dylib`.

### Heavy-C++ apps: unexport the libc++ symbols (TMO weak-coalescing trap)

`otool -L` showing only `libSystem.B.dylib` is **necessary but not sufficient** for a heavy-C++ app (iostream, exceptions, `shared_ptr`). The static libc++ emits its symbols — operator new/delete (`__TEXT,__lcxx_override`), every explicitly-instantiated iostream/locale/string method, type_info, vtables — as **weak external**. At load time dyld coalesces those weak defs with the **strong** copies the system `libc++.1.dylib` / `libc++abi.dylib` re-export via libSystem, so the **system** runtime executes instead of the statically-linked one. On macOS 15 (whose libc++ is built with "typed memory operations") the app then aborts on its first real op:

```
libc++abi: Terminating due to typed operator new being invoked before its
static initializer in libcxx has been executed.
```

e.g. `std::ifstream` → (coalesced) system `basic_filebuf::setbuf` → system *typed* `operator new`, whose TMO init (in the system `libc++.dylib` we don't link) never ran. A C-codec app (avif/aom — `FILE*`, no iostream) never instantiates these, so it never trips it. **A macOS 14 builder/CI would silently PASS** (no TMO in its system libc++) while shipping a binary that crashes for macOS 15 users — so the fix must hold cross-version, not depend on the build host.

**Fix: make the whole libc++/libc++abi symbol surface non-exported**, so dyld can't coalesce it and our static copies are kept. Pass an unexported-symbols list (wildcards) to the final link:

```nix
# multicall.nix, isDarwin branch: write the list, then append to extraLinkFlags
#   -Wl,-unexported_symbols_list,$PWD/unexport.syms
# Patterns (Itanium mangling, Mach-O leading _):
#   __Znw* __Zna* __Zdl* __Zda*                operator new / new[] / delete / delete[]
#   __ZNSt* __ZNKSt* __ZNVSt* __ZSt*           std:: members + free functions
#   __ZTVSt* __ZTVNSt* __ZTISt* __ZTINSt* __ZTSSt* __ZTSNSt*   std:: vtables / type_info
#   __ZN10__cxxabiv1* __ZNK10__cxxabiv1* __ZTVN10__cxxabiv1* __ZTIN10__cxxabiv1* __ZTSN10__cxxabiv1*
```

An executable exports nothing anyone links against, so hiding these is safe. Verify with `nm -m <bin> | grep ZNSt3__1 | grep -c 'weak external'` → must be `0` (the std:: symbols should read `non-external`). Unexporting **operator new alone is not enough** — the abort path is iostream, reached through the 400+ other weak std:: symbols (confirmed via crash backtrace: the live `setbuf` frame was in the system `libc++.1.dylib`, not the binary). Validated on `heif`. Gotcha: a literal `''` inside a Nix `''…''` string (e.g. in a comment) terminates the string — phrase around it. (`project_unpins_heif_wip`)

### When `-nostdlib++` can't work: the search-path shim

`-nostdlib++` only suppresses the **implicit** `-lc++` the compiler driver adds. It does nothing about **explicit** `-lc++`/`-lstdc++` tokens that the build itself emits, and it strips the cc-wrapper's libcxx `-L` — so any such token then fails outright with `ld: library not found for -lstdc++`. ffmpeg hits exactly this: the C++ codec deps drag libc++ in two ways at once, both defaulting to the dynamic `/usr/lib/libc++.1.dylib`:

- dep `.pc` `Libs.private` under `--pkg-config-flags=--static` — libgme emits `-lstdc++`, chromaprint `-lc++`, etc.;
- ffmpeg's own hardcoded `-lstdc++` in the `libgme`/`libopenmpt`/`librubberband`/`libsnappy` `require` probes.

These come from too many sources to suppress, and they also gate configure's lib-detection link tests, so you can't drop them. Instead make them **resolve static**: drop a `-L` shim that exposes `libc++.a` under every name those tokens ask for, ahead of the dylib dirs, and force ld64 to prefer the `.a`.

```nix
configurePhase = ''
  runHook preConfigure
  ${pkgs.lib.optionalString isDarwin ''
    mkdir -p "$TMPDIR/cxx-static"
    ln -sf ${pkgs.libcxx}/lib/libc++.a    "$TMPDIR/cxx-static/libc++.a"
    ln -sf ${pkgs.libcxx}/lib/libc++.a    "$TMPDIR/cxx-static/libstdc++.a"
    ln -sf ${pkgs.libcxx}/lib/libc++abi.a "$TMPDIR/cxx-static/libc++abi.a"
    export NIX_LDFLAGS="-L$TMPDIR/cxx-static $NIX_LDFLAGS"
  ''}
  ./configure … --extra-ldflags=-Wl,-search_paths_first --extra-libs=-lc++abi
'';
```

Three load-bearing pieces:

- **`-Wl,-search_paths_first`.** ld64 defaults to `-search_dylibs_first`: even with the shim's `-L` first, a plain `-lc++` would still find `libc++.1.dylib` in a later dir before the `.a` in the shim dir. `-search_paths_first` makes it take the first matching file in `-L` order (the shim `.a`) instead. This is the linchpin — without it the shim is silently ignored.
- **`NIX_LDFLAGS`, not `NIX_LDFLAGS_BEFORE`.** This darwin cc-wrapper does **not** honor `NIX_LDFLAGS_BEFORE` (the `-L` never reaches the link line — confirm with `make V=1`). `NIX_LDFLAGS` is prepended and lands before the sysroot dirs. Same gotcha bit the librsvg darwin fix.
- **Alias `libc++.a` as `libstdc++.a` too.** On darwin libstdc++ *is* libc++; the hardcoded `-lstdc++` tokens need a file by that name on the path.

`--extra-ldflags` lands early in ffmpeg's link line (`$LDFLAGS`), `--extra-libs` at the end (`$extralibs`). Verify with `otool -L` (only `libSystem` / Frameworks / `libobjc`). Case: ffmpeg (`ffmpeg/flake.nix`). The plain `-nostdlib++` recipe above is still correct for C++ apps that emit only the implicit `-lc++` (x265, srt, librist) — reach for the shim only when the build hardcodes explicit C++-runtime `-l` tokens.

## meson cross-file: `cpu_family` is `arm64`, not `aarch64`

On `aarch64-darwin`, nixpkgs writes `cpu_family = 'arm64'` into the meson cross-file (matching `uname -m` — see below — not the Rust/Linux `aarch64`). A library whose `meson.build` gates asm on `host_machine.cpu_family() == 'aarch64'`, or excludes `arm64` from a `.startswith('arm')` check, silently builds the wrong (or no) asm path. One-line patches add `'arm64'` alongside `'aarch64'`. Cases: libopus, dav1d, rubberband — applied via single-line entries in the `nativeFixes` registry (`feedback_meson_cpu_family_darwin_arm64`).

## `uname -m` is `arm64`, not `aarch64`

`uname -m` on Apple Silicon returns `arm64`. Linux ARM returns `aarch64`. Rust target triples and unpins' asset naming use `aarch64-apple-darwin`.

A copy-paste install command like `curl ... unpin-$(uname -m)-darwin` lands on `unpin-arm64-darwin`, which 404s.

**Don't change the CI asset naming** (keeping `aarch64` aligns with Rust target triples, the `bootstrap_naming` flag, the unpin client parser, and the Linux ARM convention). Alias at the redirect layer — `website/_redirects`:

```
/unpin-arm64-darwin  https://github.com/unpins/unpin/releases/latest/download/unpin-aarch64-darwin  302
```

Place specific aliases above the splat (`/unpin-* → .../unpin-:splat`), since Cloudflare `_redirects` matches first-rule-wins. The `unpin` client parser itself already accepts both `aarch64` and `arm64` keys (`current_arch_keys()` in `unpin/src/platform.rs`), so this only matters for hand-rolled bootstrap URLs, not for `unpin install`.

## Dead end: cross-darwin from linux

Investigated 2026-05-13. Goal: expose `packages.x86_64-linux.{darwin-x86_64,darwin-aarch64}` so dev iteration on darwin packages would not need a Mac. **Does not work on any current nixpkgs channel.**

Two distinct failure modes:

1. **nixos-25.11 / 25.05 / 24.05 / 23.11 — eval failure.** `pkgs.pkgsCross.x86_64-darwin.<anything>` hits infinite recursion at `pkgs/by-name/ap/apple-sdk/common/propagate-inputs.nix` on `${lib.getDev libiconv}/include/`. `apple-sdk` propagates `libiconv` *and* inlines `${lib.getDev libiconv}` in `buildPhase`; on darwin `libiconv = darwin.libiconv` (mkAppleDerivation → needs apple-sdk). On a darwin host the bootstrap path pre-supplies libiconv, breaking the cycle; from linux there is no such bootstrap, so it's structurally unresolvable. nixos-24.11 fails differently (libcxx assertion). Tested across hello, tree, rustPlatform — stdenv-level, package-agnostic.

2. **nixpkgs-unstable / master — eval succeeds, build fails.** The libiconv recursion is fixed, but the cross-darwin cc-wrapper drv references a second `apple-sdk-14.4.drv` whose closure contains non-cross-prefixed `Csu-88.drv`, `cctools-1010.6.drv`, etc. (linux-native variants, no `-x86_64-apple-darwin-` prefix). Building Csu fails with `clang: command not found`.

**Outcome:** the dual-pin attempt was reverted. Mac CI runners remain the only working route for darwin builds.

Do NOT re-attempt without re-checking upstream nixpkgs first. The bug is in the apple-sdk bootstrap stage's stdenv threading — not in our code, and not fixable by user-land overlays at the cross-pkgs level (overlays don't reach the bootstrap stages). The on-darwin paths (cross within darwin, native macOS builds) work fine because the bootstrap chain is correct when `build host = darwin`.

Cross-darwin status to revisit when: a nixpkgs PR mentions fixing the cross cc-wrapper's apple-sdk closure, OR aarch64-darwin native runners (M-series GitHub) become cheap enough that local-iteration without a Mac stops mattering.

## Dead end: fake-cross darwin

Also tried: import nixpkgs with `crossSystem.config = "${cpu}-apple-darwin99"` (canonical-but-versioned) while `localSystem.config` stays canonical. Goal: make nixpkgs see `hostPlatform.config != buildPlatform.config`, flip into cross mode, separate `pkgsBuildHost` → overlay applied only on host side → build-side toolchain stays cached.

Compiles in eval, **breaks on real darwin runners**. The same `config != config` signal drives autotools' cross detection. Apple SDK's `atf` (and similar) use `AC_RUN_IFELSE`-based configure probes that refuse to run in cross mode:

```
atf-aarch64-apple-darwin99> configure: error:
  cannot run test program while cross compiling
```

Hydra's cached `atf-aarch64-apple-darwin` was built natively (build == host == canonical), so `AC_RUN_IFELSE` ran fine and produced the cached drv. Any overlay that invalidates the cache forces a local rebuild of atf, which now runs configure in cross mode and bombs.

`isCross` is structural in nixpkgs — derived at package set construction from `hostPlatform.config != buildPlatform.config`, not a flag we can flip via overlay. And autotools shares the same channel. No way to fool one without fooling the other.

**Use `pkgs.pkgsStatic.<name>` + per-package `drv.override` / `drv.overrideAttrs` (shared lib fixes via `nativeFixes`).** The 30-60min "first CI" toolchain rebuild for pkgsStatic-darwin was a one-time cost already paid via `unpins.cachix.org`; new packages only rebuild themselves.

## 26.05 sunset

nixpkgs-unstable emits a deprecation warning that 26.05 will be the last release supporting `x86_64-darwin`. If/when cross-from-linux gets fixed upstream, prioritize aarch64-darwin only.
