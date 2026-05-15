# Cosmopolitan (`cosmocc`)

The Cosmopolitan toolchain ([github.com/jart/cosmopolitan](https://github.com/jart/cosmopolitan)) is unpins' escape hatch for Windows builds that the mingw cross [can't do](mingw.md#packages-blocked-on-mingw-cross): `bash`, `coreutils`, `git`, and other tools that assume POSIX `fork`/`waitpid`/signals.

Cosmopolitan implements those primitives on Windows via `CreateProcessW` + page copy + APC (no DLL singleton like MSYS), has its own libc that doesn't depend on `cygwin1.dll`, and bundles missing resources (`/etc/profile`, etc.) into the binary itself via zipos.

## Status

The workspace's `cosmocc/` directory (published as `github:unpins/cosmocc`) is the toolchain flake. Three ports live in `playground/`:

- `playground/dash` — first POC (568 KB PE32+).
- `playground/bash` — 1.85 MB PE32+, via the `superconfigure` patches.
- `playground/coreutils` — 2.1 MB PE32+ multicall via the `superconfigure` patches.

Decision pending before promoting any of these to top-level: see [Caveats](#caveats).

## When to reach for cosmocc

- The mingw cross route fails because the package assumes POSIX `fork` / `waitpid` / signals / `/etc` runtime, **and** patching nixpkgs upstream would be open-ended.
- The package already has a port in `ahgamut/superconfigure` (see [the superconfigure reference below](#superconfigure-reference)).

If `pkgsCross.mingwW64.<pkg>` works, prefer it — the cosmocc route trades the empty import table caveat (next section) for buildability.

## Caveats

1. **Empty import table.** Cosmo PE binaries call `ntdll.dll` directly via syscall numbers. CI's `grep -iE '^lib.*\.dll$'` import check passes by omission, but `ntdll` is stable de facto since NT 4.0 and **not** in the Microsoft ABI contract. The spirit of [../dynamic-link-policy.md](../dynamic-link-policy.md) is "only kernel32 / ucrtbase / system DLLs". Decide and document before promoting from `playground/`.

2. **Slow `fork()`.** ~100 ms per fork on Windows (vs ~1 ms on Linux). OK for interactive shell use; heavy configure scripts feel it.

3. **No terminfo bundle yet** for bash/coreutils ports. Readline runs in dumb mode; `stty`/`tput` may degrade in some terminals. Fix by adding a zipos asset (`BINS = bash + share/terminfo` as `superconfigure` does) or by widening `--with-fallbacks`.

4. **Wine 10.0 on Debian 13 fails on every APE and on cosmo PE binaries** — known upstream incompatibility. Smoke-test on real Windows (CI runner or VM) or skip the local sanity check.

## Toolchain mechanics (`cosmocc` 4.0.2)

### What `cosmocc` produces

- **Default**: `cosmocc -o out src.c` produces an **APE fat** binary — polyglot Linux+macOS+Windows+BSD for x86_64+aarch64. `file` reports `DOS/MBR boot sector` (MZ header at offset 0).

- **Extracting a platform-specific PE/ELF**: needs `apelink -V <bits>`:

  - `-V 1` — Linux only.
  - `-V 4` — Windows only.
  - `-V 8` — macOS only.
  - default `-V -1` — all.

  `apelink` consumes the **ELF intermediate** (`*.com.dbg`), not the APE final.

### `-save-temps` has inverted semantics in cosmocc 4.x

- **Without** `-save-temps`: intermediates appear next to the output as `<name>.com.dbg` and `<name>.aarch64.elf`.
- **With** `-save-temps`: intermediates go to `$TMPDIR/fatcosmocc.XXX.{com.dbg,aarch64.elf}` instead.

For `apelink -V 4 -o foo.exe foo.com.dbg`, **do not** pass `-save-temps`.

### `assimilate` is host-only

`assimilate` converts an APE → native format, but only for the **host**: on Linux it produces an ELF, not a PE. To extract a PE from Linux, use `apelink -V 4`.

### `-mtiny` wrapper detail

`cosmocc -mtiny` is documented but needs the `*-unknown-cosmo-cc` compiler, not the generic `cosmocc` wrapper. Use `aarch64-unknown-cosmo-cc -mtiny` / `x86_64-unknown-cosmo-cc -mtiny` directly.

## Nix packaging pitfalls

These cost time when packaging `cosmocc` itself or a cosmo-built tool.

1. **All toolchain binaries are APE static.** `ldd` reports "not dynamic"; `file` shows "DOS/MBR boot sector"; `readelf` returns empty. Set `dontPatchELF = true` and `dontStrip = true` — otherwise `stdenvNoCC` patches `interp`/`rpath` and corrupts the polyglot header.

2. **APE doesn't auto-modify in 4.x.** MD5 stays identical after running. `/nix/store` (read-only) works fine. Older versions had `ape-modify-self.o` that rewrote the header; cosmocc 4.0.2 uses `ape-no-modify-self.o` by default.

3. **`path:../<dir>` inputs don't work across flakes.** Relative paths escape the nix-store source copy. Declare `url = "github:unpins/cosmocc"` and use `--override-input cosmocc path:/abs/path` during dev. Same pattern as `unpins-lib` in the rest of the workspace.

4. **nixpkgs' `cosmocc` is 2.2.** No `apelink -V`, no `-mtiny`. Always package 4.x from `cosmo.zip/pub/cosmocc/cosmocc-4.0.2.zip` (441 MB) until nixpkgs catches up.

5. **`gnumake` as a separate input.** The derivation uses `stdenvNoCC` for the toolchain itself. Add `pkgs.gnumake` in `nativeBuildInputs` for any consumer — cosmocc is only the compiler/linker.

## The `cosmoStdenv` pattern

`cosmocc/flake.nix` exposes `lib.cosmoStdenv pkgs` — a thin wrapper over `pkgs.stdenvNoCC` that bakes in everything a cosmocc-port needs by default. Repeating the env-var dance (`CC=x86_64-unknown-cosmo-cc`, `AR=x86_64-linux-cosmo-ar`, `STRIP=...`, plus `dontPatchELF` and `dontStrip`) per derivation gets tedious; doing it once in a stdenv keeps consumer flakes legible.

```nix
inputs.cosmocc.url = "github:unpins/cosmocc";

outputs = { nixpkgs, cosmocc, ... }: let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  cosmoStdenv = cosmocc.lib.cosmoStdenv pkgs;
in {
  packages.x86_64-linux.windows-x86_64 = cosmoStdenv.mkDerivation {
    pname = "foo-windows";
    version = "1.0";
    src = ...;
    # nativeBuildInputs gets cosmocc prepended automatically.
    # CC/CXX/AR/RANLIB/STRIP/LD/NM/OBJCOPY/OBJDUMP set automatically.
    # dontPatchELF = true; dontStrip = true — defaults.
    nativeBuildInputs = [ pkgs.gnumake ];   # plus other tools as needed
    buildPhase = ''
      ./configure --prefix=$out --enable-static-link
      make
    '';
    installPhase = ''
      mkdir -p $out/bin
      apelink -V ${toString cosmoStdenv.platformBits.windows} \
        -o $out/bin/foo.exe build/foo
    '';
  };
};
```

### Deliberately NOT in `cosmoStdenv`

- **No cc-wrapper.** nixpkgs' cc-wrapper assumes glibc/musl-style linker conventions and multilib; cosmocc decides linker + two-arch output itself. Wrapping it has been a cross-cutting pain elsewhere (see [darwin.md](darwin.md) and the rest of this page). The stdenv stays slim.
- **No per-package config recipes.** Each port writes its own `buildPhase` / `installPhase` / `apelink -V` step. A higher-level helper (ncurses → readline → bash sequence) would be premature with two ports; revisit at 3+.
- **No registry slot in `nix-lib`.** Symmetrical to `mingwOverlay` would be the natural place, but `mkStandaloneFlake` doesn't route through cosmo yet — consumer flakes do a manual merge of `mkStandaloneFlake` outputs and the cosmo `windows-x86_64` derivation.

### Arch coverage

`x86_64-linux` and `aarch64-linux` hosts both work; the stdenv picks the right binutils prefix from `pkgs.stdenv.hostPlatform.parsed.cpu.name`. Other archs throw.

## Superconfigure reference

[github.com/ahgamut/superconfigure](https://github.com/ahgamut/superconfigure) is the canonical repo of cosmocc 4.x ports. Maintained by Gautham Venkatasubramanian (co-author of Cosmopolitan with Justine Tunney). **Not the same as `jart/cosmopolitan`** — that one has Python/Lua/sqlite in-tree integrated with the project's giant Makefile, irrelevant for builds using the external cosmocc 4.x toolchain.

### Layout per package

`BUILD.mk` + `check.signature` (sha256 of the tarball) + `minimal.diff` (optional) + `config-wrapper` + `fatten` (optional). Top-level categories: `cli/`, `compiler/`, `compress/`, `editor/`, `games/`, `gui/`, `lang/`, `lib/`, `python/`, `web/`.

Flow: download tarball → checksum → patch → configure → build x86_64 + aarch64 separately → `apelink` fat binary.

### Patch size is small

The heavy lifting is in `ahgamut/gcc@portcosmo-11.2` (~2000 lines in the toolchain). Per-package `minimal.diff` is tiny:

| Package | Lines | Files |
| ------- | ----- | ----- |
| bash 5.2a | 12 | 1 |
| curl 8.10.1 | 11 | 1 |
| git 2.42.0 | 208 | 6 |
| CPython 3.12.3 | 319 | 5 |

Every mingw-blocked package in the unpins fleet falls in "easy/medium" via superconfigure.

### Coverage

- `cli/`: bash, coreutils, dash, sed, grep, less, findutils, diffutils, tmux, jq, make, ninja, patch, file, zsh, toybox, bc, gperf, cmake.
- `lang/`: berry, janet, lua, php, python (3.12), tcl.
- `web/`: curl, git, gnupg, links, openssh, rsync, wget.

Pre-built binaries: [cosmo.zip/pub/cosmos/bin/](https://cosmo.zip/pub/cosmos/bin/).

### How to apply when porting something new

1. Check if `superconfigure` already has the package (categories above).
2. If yes: base the unpins flake on their `minimal.diff` + `config-wrapper` — `fetchurl` from `superconfigure` or copy in-tree.
3. If no: open an issue or PR upstream at [github.com/ahgamut/superconfigure/issues](https://github.com/ahgamut/superconfigure/issues).

### Blog posts

- [ahgamut.github.io/2023/07/13/patching-gcc-cosmo/](https://ahgamut.github.io/2023/07/13/patching-gcc-cosmo/) — toolchain design.
- [ahgamut.github.io/2021/07/13/ape-python/](https://ahgamut.github.io/2021/07/13/ape-python/) — APE for Python specifically.
- [justine.lol/cosmo3/](https://justine.lol/cosmo3/) — Cosmopolitan 3 overview.

## Per-port worked notes

### `playground/bash` (1.85 MB PE32+)

First hybrid in the fleet: native via `mkStandaloneFlake` (pkgsStatic, Linux+macOS), Windows via cosmocc. `cosmo-windows.nix` builds ncurses 6.4 → readline 8.2 → bash 5.2 in sequence in a shared `$NIX_BUILD_TOP/cosmos` prefix, then `apelink -V 4` produces `$out/bin/bash.exe`. Patches in `cosmo-patches/{bash,readline,ncurses}.diff` are copied from `superconfigure`, 54 lines total.

### `playground/coreutils` (2.1 MB PE32+)

Second `cosmoStdenv` consumer; confirms the stdenv scales. Builds `gmp 6.3.0 → coreutils 9.4` in a shared prefix. Configured with `--enable-single-binary=symlinks` for the multicall single-binary, then `apelink -V 4` on `src/coreutils`.

Quirks discovered during the port:

1. **`make src/coreutils` skips `BUILT_SOURCES`.** gnulib emits `lib/error.h` (from `lib/error.in.h`) via `BUILT_SOURCES`, which only fires as a dependency of `make all`. Just run plain `make` (single-binary already produces one ELF).

2. **`ac_cv_header_error_h=no` must be forced.** Otherwise autoconf detects `error.h` by accident (libcxx) and gnulib skips the generation — `src/mkdir-p.c #include "error.h"` then fails.

3. **`ac_cv_func_sethostname=yes` must be forced.** cosmocc declares `sethostname` in `<unistd.h>`, but autoconf detects "no" and `src/hostname.c` defines a fallback `static int sethostname(...)` that collides with the non-static header declaration.

4. **GNU stat-bit macros via CFLAGS:** `-DS_IXUGO=0111 -DS_IRUGO=0444 -DS_IWUGO=0222 -DS_IRWXUGO=0777`. Used by `lib/dirchownmod.c` and `src/install.c`. cosmocc doesn't ship them.

5. **gmp needs `--disable-fat --disable-assembly --disable-cxx`.** cosmocc doesn't consume fat-build asm dispatch tables. Plain C gives a slow but functional gmp; affects `factor`/`numfmt` on very large primes. Acceptable for MVP.

6. **gmp configure needs `nm` in `$NM`.** Added to `cosmoStdenv` (also `OBJCOPY`/`OBJDUMP`) so future ports inherit.

## Future: perl, python via Cosmopolitan

For `perl` / `python` in unpins, **do not rewrite foreign-dlopen ourselves**. Import the maintained builds from `jart/cosmopolitan` (`python.com`, `perl.com`) — analogous to the dash POC.

The root problem for static Python/Perl is `dlopen` of extensions (XS, wheels with `.so`). In musl-static pure form it doesn't work. Reimplementing the ELF loader in user space + trampolines (the foreign-dlopen route) is amateur Cosmopolitan; the upstream solution already handles the edge cases. Justine maintains Python and Perl actively.

Open decision before implementing: the empty-import-table caveat above. APE delivers one binary multi-OS, or use `apelink -V <bits>` to separate by platform (dash POC path), or accept APE as a special case. Ask the user before coding.
