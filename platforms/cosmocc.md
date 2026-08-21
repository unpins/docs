# Cosmopolitan (`cosmocc`)

The Cosmopolitan toolchain ([github.com/jart/cosmopolitan](https://github.com/jart/cosmopolitan)) is unpins' escape hatch for Windows builds that the mingw cross [can't do](mingw.md#packages-blocked-on-mingw-cross) — tools like `bash` that assume POSIX `fork` / `waitpid` / signals at runtime.

Cosmopolitan implements those primitives on Windows via `CreateProcessW` + page copy + APC (no DLL singleton like MSYS), has its own libc that doesn't depend on `cygwin1.dll`, and bundles missing resources (`/etc/profile`, etc.) into the binary itself via zipos.

> **Invariant — we ship a PE, never an APE.** cosmocc is used here *only* as a POSIX-compatibility layer to build a **Windows** binary. The cross stdenv's setup hook runs `apelink -V 4` in `fixupPhase` to extract a single **Windows x86_64 PE (`.exe`)** — the same artifact shape as a mingw build. The default APE fat/polyglot binary (one binary for Linux+macOS+Windows+BSD) is a *build intermediate only*; unpins never ships it, and external copy must not imply a universal binary ([messaging.md](../messaging.md)). So a "cosmo package" differs from a "mingw package" only in build toolchain, never in shipped format.

## Status

The toolchain lives in **`nix-lib/cosmocc.nix`** (absorbed from a separate flake on 2026-05-15). Two entry points:

- **`pkgs.pkgsCross.cosmo`** — first-class nixpkgs cross target, symmetric to `pkgs.pkgsCross.mingwW64`. The `pkgs` here is `mkStandaloneFlake`'s `windowsPkgs`, which `applyPatches`'s `nix-lib/cosmo-lib-systems.patch` onto nixpkgs (registers `cosmo` as a kernel + `examples.cosmo` crossSystem) and wires `config.replaceCrossStdenv` + the `nix-lib/cosmo/` library overlay. **The consumer-facing API** — catalog packages access it from a `./cosmo.nix` sidecar invoked via `windowsBuild = import ./cosmo.nix { inherit unpins-lib; }`. See [§ The cosmo cross set](#the-cosmo-cross-set) below. The legacy `unpins-lib.lib.cosmoStaticCross pkgs` is a passthrough alias kept for API symmetry with `lib.mingwStaticCross`.
- **`unpins-lib.lib.cosmoStdenv pkgs`** — native stdenv that wraps the cosmocc single-arch driver via cc-wrapper. The older POC pattern (in-tree prefix-tree builds) that pre-dates first-class cross; `playground/git` is its last consumer. The bash/coreutils/dash/links POCs that proved it graduated to top-level packages on the `pkgsCross.cosmo` route and their playground dirs are gone — the worked notes from those ports are kept at the end of this page.

The empty-import-table trade-off ([Caveats](#caveats)) has been accepted for packages where mingw is infeasible; see [../dynamic-link-policy.md](../dynamic-link-policy.md#cosmopolitan-caveat).

## When to reach for cosmocc

- The mingw cross route fails because the package assumes POSIX `fork` / `waitpid` / signals / `/etc` runtime, **and** patching nixpkgs upstream would be open-ended.
- The package already has a port in `ahgamut/superconfigure` (see [the superconfigure reference below](#superconfigure-reference)).

If `pkgsCross.mingwW64.<pkg>` works, prefer it — the cosmocc route trades the empty import table caveat (next section) for buildability.

## Caveats

1. **Empty import table.** Cosmo PE binaries call `ntdll.dll` directly via syscall numbers. CI's `grep -iE '^lib.*\.dll$'` import check passes by omission, but `ntdll` is stable de facto since NT 4.0 and **not** in the Microsoft ABI contract. The spirit of [../dynamic-link-policy.md](../dynamic-link-policy.md) is "only kernel32 / ucrtbase / system DLLs". Accepted for packages where mingw is infeasible (see the policy's [Cosmopolitan caveat](../dynamic-link-policy.md#cosmopolitan-caveat) section).

2. **Slow `fork()`.** ~100 ms per fork on Windows (vs ~1 ms on Linux). OK for interactive shell use; heavy configure scripts feel it.

3. **No terminfo bundle yet** for bash/coreutils ports. Readline runs in dumb mode; `stty`/`tput` may degrade in some terminals. Fix by adding a zipos asset (`BINS = bash + share/terminfo` as `superconfigure` does) or by widening `--with-fallbacks`.

4. **Wine 10.0 on Debian 13 fails on every APE and on cosmo PE binaries** — known upstream incompatibility. Smoke-test on real Windows (CI runner or VM) or skip the local sanity check.

## Windows `.exe` command lookup & multicall `argv[0]`

On Windows the installer materialises every program (and every multicall alias)
as a `<name>.exe` hardlink — `cmd.exe`/PowerShell only resolve a bare `ls` to
`ls.exe` via `PATHEXT`, so the `.exe` is mandatory. Two distinct things then
break, both because of that suffix, and both are fixed in-source rather than by
littering the directory with a second extensionless link (which would also
double every shell's tab-completion list):

1. **A cosmo shell can't find `ls`.** Cosmopolitan does **not** append `.exe`
   anywhere in its lookup→exec chain (`commandv` calls `access(name, X_OK)` with
   the exact name; `execve-nt` execs the resolved path verbatim — confirmed in
   the cosmo source). cmd/PowerShell (PATHEXT) and MSYS bash (appends `.exe`
   natively) hide this; the catalog's own cosmo shells are the only ones that
   don't. **Fix:** a `__COSMOCC__`-guarded patch per shell
   (`<shell>/findcmd-exe-lookup.patch`, applied via `postPatch` with an explicit
   `patch -p1` so it's independent of how nixpkgs applies the upstream
   `bash5x-NNN`-style patches; the file must be `git add`-ed or the flake won't
   see it). Each retries a PATH candidate with `.exe` appended when the bare name
   misses, and — critically — returns the `.exe`-bearing path so the *exec*, not
   just the existence check, uses it. Sites: bash `find_in_path_element`
   (findcmd.c); dash helper `cosmo_exe_fixup` in `find_command` + `shellexec`
   (dash stores only the PATH index and re-walks via `padvance`, so both points
   need it); mksh `search_path` / oksh `search()` (X-string ENOENT retry); tcsh
   `texec` (retry `execv` on ENOENT) **and** `tellmewhat` (so `which`/`where`
   report the `.exe`); zsh `hashcmd` (hash a `HASHED` node holding the full
   `.exe` path, else `execute()`/`findcmd()` rebuild the bare name) **and** the
   relative-`$path` loop in `execute()` (zsh never routes relative dirs through
   `hashcmd`). All six verified on a real Win10 VM (`ls` typed bare runs;
   negative control still "command not found").

2. **A multicall rejects `ls.exe`.** A multicall dispatches on `argv[0]`; an
   alias invoked as `ls.exe` (or with a `\\` path) must map to applet `ls`. The
   shared table + dispatcher generator (`lib.multicallTable`, whose `emit`
   writes both `applets.list` and `dispatcher.c`)
   already strips a trailing `.exe`/`.com` and a `\\` dir prefix (`copy_basename`
   in nix-lib), so every Windows multicall built through it
   (`e2fsprogs`/`findutils`/`procps-ng`/`srt`/`librist`/…) is already correct.
   The exceptions are the two multicalls that keep their **own** upstream
   dispatch: **coreutils** (GNU's `last_component(argv[0])` in `src/coreutils.c`)
   needs the same strip — added under `__COSMOCC__` in
   `coreutils/coreutils-cosmo.patch`; and **busybox**, which is `linuxOnly` and
   never ships on Windows, so it needs nothing.

Tab-completion is a third, separate code path (directory scan / command hash) and
is **not** affected by the lookup patch: `ls⟨Tab⟩` completes to `ls.exe` (the
on-disk name), exactly as `cmd.exe` shows it, and the completed `ls.exe` runs.
Making completion offer the bare `ls` would mean patching each shell's completion
subsystem for no functional gain — left as-is.

## Toolchain mechanics (`cosmocc` 4.0.2)

### What `cosmocc` produces

- **Default**: `cosmocc -o out src.c` produces an **APE fat** binary — polyglot Linux+macOS+Windows+BSD for x86_64+aarch64. `file` reports `DOS/MBR boot sector` (MZ header at offset 0). For unpins this is a **build intermediate only** — the cross stdenv always extracts the Windows-only PE (`-V 4`, next) and ships that, never the fat APE (see the invariant at the top).

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

3. **nixpkgs' `cosmocc` is 2.2.** No `apelink -V`, no `-mtiny`. Always package 4.x from `cosmo.zip/pub/cosmocc/cosmocc-4.0.2.zip` (441 MB) until nixpkgs catches up.

4. **`gnumake` as a separate input.** The derivation uses `stdenvNoCC` for the toolchain itself. Add `pkgs.gnumake` in `nativeBuildInputs` for any consumer — cosmocc is only the compiler/linker.

## The `cosmoStdenv` pattern

`unpins-lib.lib.cosmoStdenv pkgs` (sourced from `nix-lib/cosmocc.nix`) returns a full stdenv with `pkgs.wrapCCWith` + `pkgs.wrapBintoolsWith` around cosmocc's tools, plus `dontPatchELF` / `dontStrip` / `hardeningDisable = [ "all" ]` injected as defaults via `pkgs.stdenvAdapters.addAttrsToDerivation`. Because it's a real cc-wrapped stdenv, `buildInputs` propagate the usual way:

- headers (`$dep/include`) get `-isystem` injected by the cc-wrapper setup-hook
- libs (`$dep/lib`) get `-L` injected by the bintools-wrapper setup-hook

So derivations can list cosmo-built libs in `buildInputs` directly without any prefix-tree dance — though the prefix-tree pattern (`bash`/`coreutils`) still works because the underlying single-arch driver honors `$COSMOS`.

The returned value also carries passthru attrs: `.cosmocc` (raw zip dir, used by `playground/{dash,git}` for direct `CC=cosmocc` invocations), `.platformBits`, `.mkCrossWiring` (consumed internally by `replaceCrossStdenv` in `windowsPkgs`).

```nix
inputs.unpins-lib.url = "github:unpins/nix-lib";

outputs = { nixpkgs, unpins-lib, ... }: let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  cosmoStdenv = unpins-lib.lib.cosmoStdenv pkgs;
in {
  packages.x86_64-linux.windows-x86_64 = cosmoStdenv.mkDerivation {
    pname = "foo-windows";
    version = "1.0";
    src = ...;
    # CC/CXX/AR/RANLIB/STRIP/LD/NM/OBJCOPY/OBJDUMP set by cc-wrapper setup-hook.
    # dontPatchELF=true; dontStrip=true; hardeningDisable=["all"] — defaults.
    nativeBuildInputs = [ pkgs.gnumake ];
    buildInputs = [ /* cosmo-built static libs */ ];
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

### Why cc-wrapper, despite the warnings

The first cosmoStdenv was deliberately *slim* (`stdenvNoCC // { mkDerivation = ...; }`) because nixpkgs' cc-wrapper is famous for assuming glibc/musl conventions, multilib, and dynamic linkers. The migration to full cc-wrapper (2026-05-15) keeps cosmocc happy by:

- passing `libc = null` to `wrapCCWith` and `wrapBintoolsWith` — this short-circuits all glibc-path injection (`-B`, `-idirafter`, `-dynamic-linker`, `libc-cflags`/`libc-ldflags`);
- staying on the host platform (`x86_64-linux-gnu`), since cosmocc's APE output is *also* a valid Linux ELF — nix doesn't see this as a cross build;
- disabling every hardening flag (cosmocc has its own self-contained set; see [§ hardening](#hardening) below).

What we gain: `buildInputs` propagation works automatically, consumers stop hand-rolling `CC=…`/`AR=…`/`LD=…`, and adding cosmo-built libraries as separate derivations (vs. one giant in-tree prefix) becomes ergonomic.

### Toolchain wiring under the hood

A few non-obvious traps that the wrapped unwrapped derivations work around — preserve these when touching `nix-lib/cosmocc.nix`:

1. **Single-arch driver, not fat.** cosmocc ships both `cosmocc` (fat, multi-arch APE) and `${arch}-unknown-cosmo-cc` (single-arch). Only the single-arch driver honors `$COSMOS` (auto-injects `-L$COSMOS/lib` and `-I$COSMOS/include`); the fat driver doesn't. Bash and coreutils both set `export COSMOS=$NIX_BUILD_TOP/cosmos` in their build phase to assemble a prefix tree of static libs in-process, so they depend on this. The wrapped stdenv MUST use the single-arch driver — switching to fat silently breaks bash's final `-lncurses` link.

2. **Arch-prefix check in the driver.** `${arch}-unknown-cosmo-cc` does `ARCH=${PROG%%-*}; [ "$ARCH" = "$PROG" ] && fatal_error "cosmocross must be run via cross compiler"`. Plain `gcc` (no `-`) hits the fatal. The unwrapped cc derivation exposes `gcc`/`cc`/`g++`/`c++` as tiny `exec` shims (not symlinks), so the underlying driver sees its real arch-prefixed `$0`.

3. **Sysroot relative to `$BIN`.** The driver does `-isystem $BIN/../include` and `-L$BIN/../${arch}-linux-cosmo/lib` where `$BIN=${0%/*}`. The unwrapped cc derivation mirrors cosmocc's full layout (bin/, include/, lib/, per-arch sysroot dirs) so these resolve.

4. **`cosmoranlib` ships 0444 in upstream 4.0.2.** Other cosmo* fat scripts are 0555. The toolchain derivation does `chmod +x $out/bin/cosmoranlib` in unpackPhase. (Single-arch ranlib `${arch}-linux-cosmo-ranlib` is fine.)

5. **Bintools are `#!/bin/sh` shims, not symlinks** (added 2026-05-15 after the links/OpenSSL port). Underlying `${arch}-linux-cosmo-ar`/`ld`/etc. are APE polyglots; Linux `execve` of an APE returns `ENOEXEC`. GNU make's "no metacharacters → skip the shell" optimisation execve's `ar foo.a x.o` directly and crashes with `make: ar: No such file or directory` (OpenSSL's build was the canary). Shell invocation has the POSIX ENOEXEC-fallback path that triggers APE self-bootstrap, so wrapping each tool in a tiny `#!/bin/sh ... exec ...` shim lands every invocation back in shell. Plain symlinks for bintools are a regression trap. (Same reason `gcc`/`cc`/`g++`/`c++` are also shims — trap #2 above.)

<a name="hardening"></a>
### Hardening: all off

`cosmoStdenv` sets `hardeningDisable = [ "all" ]`. Per flag:

- **fortify / fortify3** — `_FORTIFY_SOURCE` needs glibc-style `__asm__` name redirections in headers; cosmocc's headers don't ship them.
- **stackprotector** — needs `__stack_chk_guard` symbol; cosmopolitan libc doesn't export it.
- **relro / bindnow** — `-Wl,-z,relro -Wl,-z,now` conflicts with cosmocc's default `-Wl,-z,norelro`.
- **pic** — cosmocc passes `-fno-pie` itself; `-fPIC` from the wrapper is overridden but noisy.
- **strictoverflow / format** — harmless, but no benefit since cosmocc binaries don't link against system libc.

Consumers can re-enable per-flag via `hardeningEnable = [ "stackprotector" ]` if they really want, but `addAttrsToDerivation` overwrites rather than merges `hardeningDisable`, so be careful.

### Deliberately NOT in `cosmoStdenv`

- **No per-package config recipes.** Each port writes its own `buildPhase` / `installPhase` / `apelink -V` step. `pkgs.pkgsCross.cosmo` (next section) is the answer when you want regular nixpkgs derivations rebuilt against cosmocc — but `cosmoStdenv` itself stays minimal.

### Arch coverage

`x86_64-linux` and `aarch64-linux` hosts both work; the stdenv picks the right driver/binutils prefix from `pkgs.stdenv.hostPlatform.parsed.cpu.name` via the `mkCcUnwrapped`/`mkBintoolsUnwrapped` helpers. Other archs throw.

<a name="the-cosmo-cross-set"></a>
## The cosmo cross set

`pkgs.pkgsCross.cosmo` is a first-class nixpkgs cross target — exactly the same shape as `pkgs.pkgsCross.mingwW64`. The `pkgs` flowing into `<consumer>/cosmo.nix` is `mkStandaloneFlake`'s `windowsPkgs`, where the cosmo wiring lives. Consumers reach it from a `./cosmo.nix` sidecar.

```nix
# <consumer>/cosmo.nix
{ unpins-lib }:
pkgs:
let
  cosmoPkgs = unpins-lib.lib.cosmoStaticCross pkgs;  # = pkgs.pkgsCross.cosmo
in
cosmoPkgs.<pkgsAttr>.overrideAttrs (oa: {
  # …per-binary quirks (configureFlags, postPatch, env, postInstall
  # cleanup of dangling symlinks…)
})
```

The ELF → PE32+ rename happens automatically: the cosmo cross stdenv
ships a `preFixupHook` (`nix-lib/cosmo-apelink-hook.sh`) that walks
`$out/bin`, apelinks every cosmocc-emitted ELF to `<name>.exe`, and
rewires same-directory symlinks (e.g. ncurses' `reset → tset` becomes
`reset.exe → tset.exe`). It's **fail-loud**: if a binary was stripped
during build (apelink needs `.symtab`), the build fails with a
specific message and fix recipe (`installFlags = [ "STRIP=true" ]`
or `dontCosmoApelink = true` to opt out).

Phase contract — consumer code runs at these points relative to the hook:
- `postInstall` → BEFORE auto-apelink (binaries still `<name>`)
- `postFixup`   → AFTER  auto-apelink (binaries now `<name>.exe`)

Cleanup of unwanted binaries (e.g. bash's `sh` symlink) typically
goes in `postFixup` referring to `<name>.exe`. The exception is when
upstream's own fixupPhase touches the file (e.g. shebang rewriting on
scripts that depend on the renamed binary) — then move it to
`postInstall` to act before fixup. `lib.withAliases { primary =
"<name>.exe"; ... }` works as-is since its `unpin/aliases` embed runs in
postFixup (after the hook).

```nix
# <consumer>/flake.nix
outputs = { self, unpins-lib }:
  unpins-lib.lib.mkStandaloneFlake {
    inherit self;
    name = "<name>";
    windowsBuild = import ./cosmo.nix { inherit unpins-lib; };
  };
```

Mechanism (all four pieces live in `mkStandaloneFlake`'s `windowsPkgs`, the single root from which `pkgsCross.mingwW64` and `pkgsCross.cosmo` both descend):

1. **`applyPatches` on nixpkgs source** — `nix-lib/cosmo-lib-systems.patch` (~20 lines) adds a `cosmo` kernel to `lib/systems/parse.nix`, the `isCosmo` predicate to `lib/systems/inspect.nix`, and `cosmo = { config = "x86_64-unknown-cosmo-gnu"; libc = null; }` to `lib/systems/examples.nix`. The last piece is what makes `pkgs.pkgsCross.cosmo` resolvable.
2. **`config.replaceCrossStdenv`** — guarded on `baseStdenv.hostPlatform.isCosmo`: when nixpkgs builds the cosmo cross stdenv, swap its cc/bintools for cosmocc's via `mkCrossWiring { buildPackages, baseStdenv, targetPrefix, targetArch }`. The wiring also wraps the result with `stdenvAdapters.makeStaticLibraries` (cosmocc can't emit `.so`) and adds a setup-hook that patches `config.sub` to accept `cosmo-gnu` (no `gnu-config` derivation override, so xgcc bootstrap stays cached). For non-cosmo crosses (mingwW64), the guard returns `baseStdenv` unchanged — drv hashes stay byte-identical to a vanilla `import nixpkgs`.
3. **Library-only overlay fragments** — `nix-lib/cosmo/<lib>.nix` files (`libedit`, `libevent`, `ncurses`, `openssl`) are auto-discovered and applied at the `windowsPkgs` root. Each is `{ lib }: final: prev: { ... }`, gated on `prev.stdenv.hostPlatform.isCosmo` so it only affects `pkgsCross.cosmo`, not `pkgsCross.mingwW64` (whose drv hashes stay unchanged) or `buildPackages` (which would invalidate cache.nixos.org hashes). These libs are cosmo-patched because **other packages depend on them transitively**; per-binary recipes live inline in the consumer flake's `cosmo.nix` sidecar, not in this directory.

```nix
# nix-lib/cosmo/ncurses.nix — transitive lib overlay (kept in nix-lib)
{ lib }:
final: prev:
if (prev.stdenv.hostPlatform.isCosmo or false) then {
  ncurses = prev.ncurses.override {
    enableStatic = true;
    unicodeSupport = false;  # cosmo's wchar.h split breaks widec ncurses
  };
} else { }
```

### When to use each entry point

- **`cosmoStdenv`** for in-tree prefix-tree builds where you control the whole `buildPhase` and want to call `cosmocc` directly — currently only `playground/git`. The pattern matches `superconfigure`'s shape and pre-dates first-class cross.
- **`pkgs.pkgsCross.cosmo`** for catalog packages — "I just want `pkgs.openssl` cosmo-flavoured" — when the package builds cleanly via autotools and you only need a per-binary quirk file in `<consumer>/cosmo.nix`. Most packages need `NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1` because their `meta.platforms` doesn't list cosmo.

### Cross-arch caveat

The `examples.cosmo` crossSystem hard-codes `x86_64-unknown-cosmo-gnu`. The cosmocc 4.0.2 zip ships both `x86_64` and `aarch64` single-arch drivers and `mkCrossWiring` synthesizes the right arch-prefixed shims, so a second `examples.cosmo-aarch64` entry would unlock that target — not added yet because no catalog package needs it.

### Growing the lib overlay

When you hit a cosmo-build failure that's a transitive library failure (e.g. libevent's `if_nametoindex` not in cosmo's `net/if.h`) AND the lib is consumed by multiple downstream packages, add `nix-lib/cosmo/<lib>.nix` with an `isCosmo`-gated override. Mirror `ahgamut/superconfigure`'s `minimal.diff` for that lib whenever possible. For a per-binary fix that only affects one consumer, keep the override local to that consumer's `./cosmo.nix`.

### Transitive deps to dead references

Some nixpkgs derivations bake references to other packages (e.g. nixpkgs `findutils` substitutes `${coreutils}/bin/echo` into `xargs.c`). When those references are **dead at runtime** for our shipped artifact, override them to a vanilla `pkgs.<dep>` instead of the cosmo cross version — this keeps the cosmo overlay narrow and avoids dragging transitive packages into the lib overlay. `findutils/cosmo.nix` is the canonical instance: `(cosmoPkgs.findutils.override { coreutils = pkgs.coreutils; }).overrideAttrs …`.

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

## Per-port worked notes (historical — from the retired playground POCs)

### bash POC (1.85 MB PE32+)

First hybrid in the fleet: native via `mkStandaloneFlake` (pkgsStatic, Linux+macOS), Windows via cosmocc. `cosmo-windows.nix` builds ncurses 6.4 → readline 8.2 → bash 5.2 in sequence in a shared `$NIX_BUILD_TOP/cosmos` prefix, then `apelink -V 4` produces `$out/bin/bash.exe`. Patches in `cosmo-patches/{bash,readline,ncurses}.diff` are copied from `superconfigure`, 54 lines total.

### coreutils POC (2.1 MB PE32+)

Second `cosmoStdenv` consumer; confirms the stdenv scales. Builds `gmp 6.3.0 → coreutils 9.4` in a shared prefix. Configured with `--enable-single-binary=symlinks` for the multicall single-binary, then `apelink -V 4` on `src/coreutils`.

Quirks discovered during the port:

1. **`make src/coreutils` skips `BUILT_SOURCES`.** gnulib emits `lib/error.h` (from `lib/error.in.h`) via `BUILT_SOURCES`, which only fires as a dependency of `make all`. Just run plain `make` (single-binary already produces one ELF).

2. **`ac_cv_header_error_h=no` must be forced.** Otherwise autoconf detects `error.h` by accident (libcxx) and gnulib skips the generation — `src/mkdir-p.c #include "error.h"` then fails.

3. **`ac_cv_func_sethostname=yes` must be forced.** cosmocc declares `sethostname` in `<unistd.h>`, but autoconf detects "no" and `src/hostname.c` defines a fallback `static int sethostname(...)` that collides with the non-static header declaration.

4. **GNU stat-bit macros via CFLAGS:** `-DS_IXUGO=0111 -DS_IRUGO=0444 -DS_IWUGO=0222 -DS_IRWXUGO=0777`. Used by `lib/dirchownmod.c` and `src/install.c`. cosmocc doesn't ship them.

5. **gmp needs `--disable-fat --disable-assembly --disable-cxx`.** cosmocc doesn't consume fat-build asm dispatch tables. Plain C gives a slow but functional gmp; affects `factor`/`numfmt` on very large primes. Acceptable for MVP.

6. **gmp configure needs `nm` in `$NM`.** Now set automatically by the bintools-wrapper setup-hook from PATH lookup (it exports `AR`/`AS`/`LD`/`NM`/`OBJCOPY`/`OBJDUMP`/`READELF`/`RANLIB`/`STRIP`/`STRINGS`/`SIZE`/`WINDRES`); when adding a new tool name, just make sure it's symlinked in `cosmoBintoolsUnwrapped`'s `bin/`.

## Resolved: perl and python ship without cosmo

An earlier note here recommended importing `jart/cosmopolitan`'s maintained `python.com` / `perl.com` if perl/python ever joined the catalog (the worry was `dlopen` of extensions under musl-static). That's moot: both ship today as top-level packages built with the unpin-llvm engine — see `perl/flake.nix` and `python/flake.nix` for how the extension question was actually handled.
