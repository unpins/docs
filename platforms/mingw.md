# Windows / mingw cross

unpins' Windows builds cross-compile from Linux runners via `pkgsCross.mingwW64`. The output is a single PE32+ binary, fully statically linked except for the system DLLs listed in [../dynamic-link-policy.md](../dynamic-link-policy.md).

The `mingwStaticCross pkgs` helper in `nix-lib` is the entry point — see [../architecture.md](../architecture.md). This doc covers the gotchas that you hit while writing or porting a package.

## POSIX shim gaps

mingw-w64's headers target the Win32 API surface, not POSIX. Setting `_GNU_SOURCE` or `_POSIX_C_SOURCE` doesn't unlock the missing types or symbols.

When a `pkgsCross.mingwW64.<pkg>` build fails with `<pwd.h>: No such file or directory` or `unknown type name 'u_long'`, write a single header patch that adds these shims. Don't blame the cross-toolchain — it's working as designed; the tool's source assumes POSIX.

**Headers absent:**

- `<pwd.h>`, `<grp.h>`, `<langinfo.h>`, `<sys/socket.h>`

**Functions absent (or in odd locations):**

- `getpwuid` / `getgrgid` → stub returning `NULL` (callers usually handle this).
- `nl_langinfo(CODESET)` → stub returning `"UTF-8"`.
- `readlink` → stub returning `-1` (Windows symlinks ≠ POSIX symlinks).
- `realpath` → stub returning `NULL` (callers degrade gracefully) or wrap `_fullpath`.
- `gethostname` exists but drags `ws2_32`; stub to `"localhost"` if only used cosmetically.

**Stat constants absent:**

- `S_IFLNK`, `S_IFSOCK`, `S_ISUID`, `S_ISGID`, `S_ISVTX` — define as unique-within-`S_IFMT` (lstat == stat on Win so they never match real files anyway).

**BSD typedefs absent:**

- `uid_t`, `gid_t`, `u_int`, `u_long`, `u_short`, `u_char` — typedef to the matching unsigned ints.
- `pid_t` *is* provided by MinGW; don't re-typedef it (`error: conflicting types`).

**lstat:** MinGW provides it, but `#define lstat stat` is simpler and produces identical behavior.

Reference: `tree/tree-mingw.patch` — canonical, ~70 lines, single `#ifdef _WIN32` block in the project's main header.

Validate with a quick local `x86_64-w64-mingw32-cc -c` cycle before wiring into the flake.

## Static-link pitfalls (libidn2 / libpsl / libunistring / libiconv chain)

Forcing `pkgsCross.mingwW64.<lib>` into static-only via `--disable-shared` chains several non-obvious problems together. Same hazards apply to any package using `libidn2` / `libpsl` / `libunistring` / `libiconv` (curl, wget, gnupg).

1. **Don't use `pkgs.extend overlay` to flip libs static.** It propagates to the toolchain — `xgcc-14.3.0` gets rebuilt because gcc itself depends on `zlib`/`zstd`. Use per-input `pkg.override { lib = ... }` so only the consumer's deps change. See [`overlay-invalidates-pkgsbuildhost`](#why-not-overlays-for-per-package-fixes) for the darwin variant of this rule.

2. **Each lib has its own static knob:**

   - `brotli` (cmake): `.override { staticOnly = true; }`
   - `zlib` (custom): `.override { shared = false; }`
   - `zstd` (cmake): `.override { static = true; }`
   - `libiconv` (autotools): `.override { enableShared = false; }` works directly, but in cross splice contexts the `.override` may be missing — use `overrideAttrs` adding `--disable-shared --enable-static` instead.
   - autotools libs (`libidn2`, `libunistring`, `libpsl`, `nghttp2`): `overrideAttrs` adding `dontDisableStatic = true` + `--disable-shared --enable-static`.

3. **`__imp_*` undefined references mean header dllimport mismatch.** A static `.a` was compiled against a *shared* dep's header (which has `__declspec(dllimport)`). Fix by passing the static dep via the consumer's `.override`, e.g. `cross.libpsl.override { libunistring = static-libunistring; }`. `libunistring/woe32dll.h` shows this clearly.

4. **Static link is single-pass left-to-right.** A lib's `.o` files are pulled in only to satisfy refs that are *already* undefined. So consumers must precede providers: `-lpsl -lidn2 -lunistring -liconv`. Wrong order = `undefined reference to u8_to_u32` etc. Curl uses `pkg-config --libs-only-l` which strips `-Wl,--start-group`, so reorder `Libs:` in the `.pc` file directly via `postFixup`.

5. **`pkg-config` `Libs.private` vs `Libs:`.** `PKG_CHECK_MODULES` in autoconf only consumes `Libs:`. Promote private into `Libs:` when the lib is used statically, otherwise `AC_CHECK_LIB` link probes fail.

6. **`strictDeps = true` consumers (like curl) need `propagatedBuildInputs`** for transitive libs to reach `NIX_LDFLAGS`. Adding to `buildInputs` is not enough — only propagated inputs of immediate deps contribute `-L` paths.

7. **libunistring on non-Linux propagates libiconv.** If you static-flip libunistring without overriding its libiconv, the *shared* libiconv path leaks into the consumer's `NIX_LDFLAGS` before the static one and the linker picks `.dll.a` over `.a`. Fix: `(asStaticOnly cross.libunistring).override { libiconv = static-libiconv; }`.

8. **libidn2's `bin` output (`idn2.exe`) imports `libiconv-2.dll`.** Even if you don't ship `idn2.exe`, that bin output is in libidn2's outputs and brings shared libiconv into the consumer's closure. Drop the `bin` output via `overrideAttrs { outputs = filter (o: o != "bin") old.outputs; }` plus `postInstall` cleanup.

9. **`-DXXX_STATICLIB` defines** are needed when consuming nghttp2 (and a few other libs whose headers default to `__declspec(dllimport)` for the consumer). Set via `NIX_CFLAGS_COMPILE`. For curl: `-DNGHTTP2_STATICLIB -DCURL_STATICLIB -DPSL_STATIC`.

10. **`pkgsCross.mingwW64.pkgsStatic.<pkg>` is broken.** It regenerates the host triple as `x86_64-w64-windows-gnu`, which `config.sub` rejects. The "correct" alternative `crossSystem = { config = "x86_64-w64-mingw32"; isStatic = true; }` rebuilds the entire GCC toolchain (no binary cache, ~1h). Stick with manual per-input overrides via `mingwStaticCross`.

11. **The `win-dll-link.sh` setup hook** (auto-applied to all mingw cross derivations) reads `objdump -p` of each output `.exe`/`.dll` and copies any imported non-system DLLs from `LINK_DLL_FOLDERS` into `$bin/bin/`. If the `.exe` is linked statically and only imports system DLLs, this hook is a no-op. So fully-static `.exe` ⟹ no companion DLLs (the rule from [../dynamic-link-policy.md](../dynamic-link-policy.md)).

Reference implementation: `curl/flake.nix`.

## Fake-static libraries

Some upstreams only build a shared library plus an import library, and ship a `libfoo.a` that is just a *symlink* to `libfoo.dll.a` (the import lib). Even with `LDFLAGS=-all-static` the resulting binary imports the DLL.

Diagnostic: `objdump -p result/bin/<pkg>.exe | grep 'DLL Name'` shows a `lib*.dll`.

Fix: rebuild a real static archive from the lib's object files. For single-source libraries like `libgnurx` (just `regex.o`):

```nix
libgnurxStatic = cross.windows.libgnurx.overrideAttrs (old: {
  postBuild = (old.postBuild or "") + ''
    $AR rcs libgnurx-real.a regex.o
  '';
  postInstall = ''
    install -m 644 libgnurx-real.a $out/lib/libgnurx.a
    rm -f $out/lib/libgnurx.dll.a $out/lib/libregex.a
    rm -f $out/bin/libgnurx-0.dll
    rmdir $out/bin 2>/dev/null || true
  '';
});
```

Then re-thread into the consumer: `cross.file.override { libgnurx = libgnurxStatic; }`. Reference: `file/flake.nix`.

## Packages blocked on mingw cross

Documented dead ends — do not retry without a concrete upstream change to point to.

### bash (5.2 / 5.3)

`pkgsCross.mingwW64.bash` fails with `_sigset_t` undefined in `support/man2html.c` and `mksyntax.exe` failing in `builtins/`. bash isn't really meant to cross-compile to Windows; nixpkgs doesn't apply enough patches.

Anything pulling bash transitively will also fail:

- `gnutls` → `unbound` → `bash`.
- `samba` → `bash`.
- Any derivation with `make-shell-wrapper-hook` in `nativeBuildInputs` at cross time.

For ffmpeg: pass `withGnutls = false` and `withSamba = false`. For git: no clean override exists; either use a custom `Make_ming.mak`-style build or go [cosmocc](cosmocc.md).

The shipped path for bash on Windows is Cosmopolitan — see `playground/bash/cosmo-windows.nix` (1.85 MB PE32+).

### git

Blocked at every layer:

- `pkgsCross.mingwW64.bash` fails (above).
- `pkgsCross.mingwW64.gawk` fails (`regex_internal.h: langinfo.h: No such file or directory`). Workaround via `buildPackages.gawk` only goes one layer deep.
- `pkgsCross.mingwW64.libev` fails (libtool no-undefined). Bypassable with `http3Support = false`.
- `pkgsCross.mingwW64.nghttp3` fails (`fatal error: arpa/inet.h: No such file or directory`).

From-scratch attempts (own `mkDerivation` with `make NO_CURL=1 NO_OPENSSL=1`) get past dep issues but hit POSIX header errors because git's Makefile assumes Linux unless `uname_S=MINGW*` is set. Even then, `git filter-branch` / `git rebase -i` need a POSIX shell at runtime — not shippable as single-binary on Windows.

Shipped path: native-only (Linux + Darwin). Windows route in `playground/git/` via embedded dash + on-demand extraction of the shell-script subcommands.

### coreutils

`pkgsCross.mingwW64.coreutils` (9.8 in nixos-25.11) fails in `lib/savewd.c` — gnulib uses `waitpid`, which Windows doesn't have. Shimming waitpid + the rest of the fork/signal surface would be open-ended.

Shipped path: native uses `pkgs.pkgsStatic.coreutils` (multicall, symlinks dropped). Windows via Cosmopolitan in `playground/coreutils/cosmo-windows.nix` (2.1 MB PE32+).

### Other transitive dead ends in 25.11 cross-mingw

- `libtheora` 1.1.1 (ld treats `.dll.def` as a linker script).
- `x265` 3.5 (CMake error).
- `fftw` (gfortran-cross-wrapper broken — pulled by `speex`).
- `rav1e` (Rust toolchain too).
- `svt-av1` (3.1.2 renamed `svt_av1_enc_init_handle`; ffmpeg 8.0 still uses old name).

For ffmpeg, drop those codecs (see [../big-packages.md](../big-packages.md)).

## Why not overlays for per-package fixes

`pkgs.appendOverlays` works on linux runners (the build-host stays cached), but the same pattern on darwin invalidates `pkgsBuildHost.stdenv` and triggers ~30-60 min toolchain rebuilds. We use `drv.override` / `drv.overrideAttrs` inside `fixes.<name>.<platform>` entries instead — see [darwin.md](darwin.md) for the cascade details.

The exception is `fixes.<name>.mingwOverlay`: those *are* applied as overlay pieces by `mingwStaticCross`. Safe on mingw because `pkgsBuildHost` of the cross set is linux, so the overlay's `if isMinGW` gate skips the build side entirely.
