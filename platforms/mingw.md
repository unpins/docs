# Windows / mingw cross

unpins' Windows builds cross-compile from Linux runners via `pkgsCross.mingwW64`. The output is a single PE32+ binary, fully statically linked except for the system DLLs listed in [../dynamic-link-policy.md](../dynamic-link-policy.md).

The `mingwStaticCross pkgs` helper in `nix-lib` is the entry point — see [../architecture.md](../architecture.md). A package that sets `multicall.windows = true` additionally routes its build through the unpin-llvm engine (bitcode + self-folded dispatcher) on top of this cross set — but parts of the dependency chain still build through the gcc-based mingw path documented here, so the gotchas below stay live either way.

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

## Static `.pc` link-resolution traps (provider side)

The chain above is *consumer*-side (curl threading static idn/psl). The opposite class shows up when **you ship a static lib that another package consumes via `pkg-config --static`** (ffmpeg, srt, librist). The lib builds fine, but the consumer's link fails — or worse, silently re-imports a DLL. Three recurring shapes; diagnose with `objdump -p result/bin/<pkg>.exe | grep 'DLL Name'` (unexpected `lib*.dll`) and `nm -u <lib>.a | grep __imp_` (unresolved Win32/runtime imports).

### (A) C++ lib leaks a *dynamic* `-lgcc_s` into `Libs.private`

CMake C++ libraries (x265, srt's `haisrt`) run an exception-handling link probe **without** `-static-libgcc`, so CMake bakes the *dynamic* gcc-runtime sequence (`-lgcc_s …`) into the `.pc` `Libs.private`. A consumer doing `pkg-config --static` re-injects `-lgcc_s`; the `libgcc_s.dll.a` import lib then wins over `libgcc_eh.a`, and the final `.exe` imports `libgcc_s_seh-1.dll` — a forbidden companion DLL.

Fix in the lib's `postFixup` (mingw branch): sed the `.pc` so `Libs.private` carries the **static** runtime sequence instead:

```bash
sed -i -e 's|^\(Libs.private:\).*|\1 -lstdc++ -lgcc -lgcc_eh -lmcfgthread -lntdll|' \
  "$out/lib/pkgconfig/<lib>.pc" "$dev/lib/pkgconfig/<lib>.pc"
```

This was the keystone that unblocked **x265 / svt-av1** in ffmpeg-on-Windows (both listed as "dead ends" in older notes — they aren't). See `nix-lib/native-overlay/x265.nix`, auto-memory `feedback_mingw_pc_libgcc_s_probe_trap`.

### (B) Static lib forgets its Win32 syscall deps in `Libs.private`

A static `.a` that calls Winsock / IPHLPAPI / Bcrypt / winpthreads doesn't record the matching `-l<sysdll>` in its `.pc`, because the *shared* build resolved them implicitly. The consumer link then fails on `__imp_<API>` undefined. This also surfaces the first time anything links an **executable** against the lib — a lib-only consumer (ffmpeg wanting `librist.a`) never hits it, but the standalone tools do (this is exactly the `librist` tools needing `-lwinpthread -lbcrypt`).

Diagnose: `nm -u <lib>.a | grep __imp_`, then map the symbol to its DLL:

| Undefined `__imp_*` symbol | Append to the link |
| -------------------------- | ------------------ |
| `WSAStartup`, `socket`, `recv`, … | `-lws2_32` |
| `if_nametoindex`, `GetAdaptersAddresses`, … | `-liphlpapi` |
| `BCryptGenRandom`, `BCrypt*` | `-lbcrypt` |
| `pthread_mutex_lock`, `pthread_create`, `clock_gettime` | `-lwinpthread` |
| `CertOpenStore`, `CryptAcquireContext`, … | `-lcrypt32` |
| `InitSecurityInterfaceA` (Schannel SSPI) | `-lsecur32` |
| `CoCreateInstance`, COM | `-lole32` |

Fix where it's cheapest: append to the lib's `.pc` `Libs.private` (so every consumer gets it), or — for a one-off standalone tool link — append to that link via `NIX_LDFLAGS` (lands after the archive group, so it resolves; see `librist/multicall.nix`). Cases: mbedtls (`-lbcrypt`, threading `-lwinpthread`), libssh (`-lws2_32 -liphlpapi`). See `feedback_mingw_libs_private_winapis`.

### (C) `Requires.private` dropped → "lib >= X not found"

Covered cross-platform in [../static-linking.md](../static-linking.md#pc-files-and-the-static-linker) — sed `Requires.private:` → `Requires:` plus propagate. Hits brotli / fontconfig / libtiff / libthai / glib transitively under mingw.

### (D) Header defaults to `__declspec(dllimport)` with no static fallback

A generalization of item 3 above. A library's public header decorates its API with `__declspec(dllimport)` under `_WIN32` and provides no `*_STATIC` escape; the consuming `.a` then references `__imp_<sym>` that the static archive doesn't define. Two variants:

- **Lib ships a `.pc`** → inject `-D<NAME>_STATIC` into its `Cflags` (`postFixup` sed), so consumers compile against the static-decorated declarations. (curl's `-DNGHTTP2_STATICLIB -DCURL_STATICLIB -DPSL_STATIC` are this.)
- **No `.pc`** → patch the header to default to static linkage under `_WIN32`.

Confirmed: chromaprint, libssh, twolame; expected for gdbm, libgcrypt, sqlite, libuv, nghttp2. See `feedback_mingw_dllimport_static_pattern`.

## Rust → mingw single binary

A Rust CLI cross-compiled to `x86_64-pc-windows-gnu` ships, by default, alongside `libstdc++-6.dll` / `libgcc_s_seh-1.dll` / `libmcfgthread-2.dll`. Three fixes collapse it to one `.exe` (validated on `rsvg-convert`):

1. **`+crt-static`** — sed it into `.cargo/config.toml`'s `rustflags` (the env-var form is dropped by some build scripts).
2. **Static runtime on the search path** — copy the static `libstdc++.a` / `libmcfgthread.a` into a dir and pass `-L native=$TMPDIR/static-rt`; the GNU Rust target otherwise picks the `.dll.a` import libs.
3. **`-lntdll -lkernel32` *after* `-lmcfgthread`** — mcfgthread's TLS uses Win32 APIs that must resolve after it on the single-pass link.

Plus **`-Wl,--allow-multiple-definition`**: a Rust staticlib and libgcc both define `___chkstk_ms` / `__udivmodti4` / `__udivti3`, and the COMDAT/weak dedup doesn't survive two static archives — let the first definition win. (`feedback_mingw_rust_compiler_builtins_collision`, `feedback_unpins_rust_mingw_single_binary`)

Dead ends: bare `-static` (over-links, breaks), `SYSTEM_DEPS_LINK=static` (no effect here).

## C++ `std::thread` → mingw `libmcfgthread-2.dll`

The mingw GCC here uses the **`mcf` thread model** (`x86_64-w64-mingw32-gcc -v` → `Thread model: mcf`), so libstdc++'s `std::thread` / `std::mutex` resolve through **libmcfgthread**. A C++ program (or C apps linking a C++ `.a`) that touches `std::thread` then imports `libmcfgthread-2.dll` — rejected by the portability gate — **even with `-static -static-libgcc -static-libstdc++`**, because mcfgthread is a separate library and the compiler driver appends an implicit *dynamic* `-lmcfgthread` after the command-line libs (anything that resets the linker to `-Bdynamic` first — e.g. libjxl's `JPEGXL_STATIC` `link_libraries(… -Wl,-Bdynamic)` — guarantees it).

Fold the static archive in explicitly:

```nix
extraLinkFlags = "-static -static-libgcc -static-libstdc++ -Wl,-Bstatic -lmcfgthread -Wl,-Bdynamic";
buildInputs = [ scope.windows.mcfgthreads ];   # provides lib/libmcfgthread.a on the link path
```

`-Wl,-Bstatic -lmcfgthread` forces the `.a` over the `.dll.a`; symbols are then defined, so the driver's later implicit dynamic `-lmcfgthread` imports nothing. Verify: `objdump -p <bin>.exe | awk '/DLL Name:/{print $NF}'` must list only uppercase system DLLs (`KERNEL32`/`msvcrt`/`ntdll`). Only surfaces for tools that actually use `std::thread` (`jxl`'s cjxl/djxl hit it; `avif`/`aom` don't). Same root cause as the Rust mcfgthread fix above. (`feedback_mingw_mcfgthread_stdthread_static_fold`)

## Combined C++ multicall link: binutils PE-COMDAT bug → use lld

A C++ multicall whose folded archives carry heavy C++ (`heif`: libde265 + x265 + libheif, all C++) can fail the **combined** link under binutils `ld` with a wall of:

```
undefined reference to `std::__cxx11::basic_string<…>::_M_dispose()'
undefined reference to `std::_Sp_counted_base<…>::_M_release_last_use_cold()'
```

— though those symbols **are present** in `libstdc++.a` (`nm` confirms). CMake's per-tool `.exe` links resolve them fine; only the larger combined link (the template app's objects + the sibling mains) trips it. It's a binutils 2.44 PE/COFF bug: in a large link its COMDAT-group selection discards the archive member that *defines* the symbol, leaving the reference dangling. An `ld -r --whole-archive` pre-merge does **not** help — `ld -r` preserves COMDAT groups rather than collapsing them to plain defs, so the merged object re-exposes the same undefined COMDAT (and it cascades: each C++ archive re-introduces it).

**Fix: drive the combined link with lld instead of binutils ld** — lld's PE/COFF COMDAT selection doesn't have the bug, so a plain static C++ link just works, with none of the GNU-ld workarounds (no `--start-group`, no archive pre-merge, no `--allow-multiple-definition`, no `-nostdlib++`):

```nix
windowsBuild = pkgs:
  mk pkgs (ulib.mingwStaticCross pkgs) {
    extraLinkFlags = "-static -static-libgcc -static-libstdc++ -fuse-ld=lld";
  };
# + pkgs.buildPackages.lld in the multicall derivation's nativeBuildInputs
#   (the cross gcc driver invokes `ld.lld` from PATH)
```

Scope it to the **combined** link only — CMake's per-tool links are fine under binutils ld, so no toolchain change is needed, just the one linker flag + lld on the build path. Validated on `heif` (libde265+x265+libheif+aom+dav1d → 35 MB PE32+ importing only KERNEL32/msvcrt/ntdll, full encode/decode roundtrip on the smoke VM). avif/aom don't hit it (apps mostly C) and jxl links OK under GNU ld too — reach for lld only when the combined C++ link shows the COMDAT-discard `undefined reference`s above. (`project_unpins_heif_wip`)

## readdir / directory enumeration: prefer cosmocc

msvcrt's `readdir` returns filenames through `WideCharToMultiByte(CP_ACP, …)` — it **silently drops** CJK / emoji / often Latin-1 filenames (data loss, not a rendering issue). Any package that *enumerates* directories (`tree`, `findutils`, `coreutils`, `ls`) is wrong on Windows under mingw. Cosmopolitan keeps filenames UTF-8 internally and exposes them correctly, so for directory-walking tools the Windows target goes through [cosmocc.md](cosmocc.md) instead — the 350–440 KB size penalty is the cost of correctness, and it overrides the usual "cosmo only when no native option" preference. (`feedback_mingw_readdir_ansi_data_loss`)

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

Packages that don't cross-compile cleanly via `pkgsCross.mingwW64`, and how each one actually reaches Windows. The mingw dead ends here are real — don't retry the mingw path without a concrete upstream change to point to — but `bash` and `coreutils` ship via [cosmocc](cosmocc.md) instead, and `git` is a viable work-in-progress on mingw (below).

### bash (5.2 / 5.3)

`pkgsCross.mingwW64.bash` fails with `_sigset_t` undefined in `support/man2html.c` and `mksyntax.exe` failing in `builtins/`. bash isn't really meant to cross-compile to Windows; nixpkgs doesn't apply enough patches.

Anything pulling bash transitively will also fail:

- `gnutls` → `unbound` → `bash`.
- `samba` → `bash`.
- Any derivation with `make-shell-wrapper-hook` in `nativeBuildInputs` at cross time.

For ffmpeg: pass `withGnutls = false` and `withSamba = false`. For git, the clean override *does* exist — pin the build-host `bash`/`gawk`/`gnused`/`coreutils` to native (`buildPackages.*`) so the cross-bash chain never triggers; see the git recipe below.

The shipped path for bash on Windows is Cosmopolitan — see `unpins/bash/cosmo.nix` (1.85 MB PE32+); bash has been promoted out of `playground/bash/`.

### git

**Status: not shipped — parked in `playground/git`** (whose flake has since focused on the native multicall build), pending the runtime-shell embed port (last subsection below). The mingw recipe below was validated 2026-05-15 and is preserved as the starting point for whoever picks it back up.

Cross-mingw IS viable. Multicall folds helpers into a single PE32+ (~5.6 MB pre-static cascade, ~7-8 MB after static curl). The "blocked at every layer" story from earlier sessions was wrong: every dep-chain failure was a spurious cross-build of a tool that `gitMinimal` only uses to rewrite shebangs of shell scripts we delete anyway, OR was bypassable with a knob already used by other unpins packages. The single real source bug was patched in 5 lines.

**Recipe** (`gitMinimal.override` + `.overrideAttrs`):

1. **Build-host tool overrides** (none of these are runtime deps; nixpkgs' `gitMinimal` only uses them to substitute `${pkg}/bin/foo` paths into `git-filter-branch` etc., which we drop):

   ```nix
   bash = buildPackages.bash;
   gawk = buildPackages.gawk;
   gnused = buildPackages.gnused;
   gnugrep = buildPackages.gnugrep;
   coreutils = buildPackages.coreutils;
   ```

   These cancel the cross-mingw builds of bash/gawk/sed (any of which still fail upstream; sed needs `-lbcrypt` for `getrandom`, gawk needs `langinfo.h`, etc.).

2. **Drop `make-shell-wrapper-hook`** from `nativeBuildInputs` via filter. The hook's `.shell` substitution resolves to `targetPackages.runtimeShell` (cross bash); but `gitMinimal` has `perlSupport = false`, so the wrapper is never invoked — pure dead weight that drags cross bash into the closure.

3. **`http3Support = false`** on the curl override. Same recipe as `unpins/curl`. Bypasses cross-mingw `libev`/`nghttp3` failures.

4. **`zlib-ng = zlib`** override. nixpkgs' cross `zlib-ng` ships only `libzlib-ng.dll.a` (no static), so the static link fails. Plain zlib works; pair with `makeFlags` filter to drop `ZLIB_NG=1`.

5. **`dontConfigure = true`**. Running `./configure` generates a `config.mak.autogen` that contradicts the `compat/win32/*.h` headers — e.g. autoconf decides `NO_INET_PTON=1` because its probes fail (no `<sys/socket.h>` on mingw), but `compat/mingw-posix.h` already declares `inet_pton`. Skip configure entirely; rely on the Makefile's `uname_S=MINGW` branch.

6. **`makeFlags`**:

   ```
   uname_S=MINGW       # force the MINGW branch in config.mak.uname
   MSYSTEM=MINGW64     # avoid -D_USE_32BIT_TIME_T fallback (incompatible with _WIN64)
   NO_GETTEXT=YesPlease   # gettext.h still includes <libintl.h> unless this is set
                          # (USE_GETTEXT_SCHEME=fallthrough alone is not enough)
   USE_LIBPCRE=        # override the MINGW block's USE_LIBPCRE=YesPlease
   CC=<target>-gcc
   AR=<target>-ar
   RC=<target>-windres -O coff
   INSTALL=install
   CURL_CONFIG=${curl.dev}/bin/curl-config
   ```

7. **Patch `compat/win32/pthread.h`**: the `pthread_sigmask` stub is gated by `#ifndef __MINGW64_VERSION_MAJOR`, but the same header defines `PTHREAD_H` at the top so the real winpthreads `<pthread.h>` (which would provide `pthread_sigmask`) is never included. Drop the gate — make the stub unconditional. This is a latent bug in git that git-for-windows' MSYS2-specific build environment papers over.

8. **postInstall**: fix nixpkgs git's `bin/git-http-backend → libexec/git-core/git-http-backend` symlink — on Windows the target is `git-http-backend.exe`. Walk `$out/bin/` and re-link any dangling symlinks with `.exe` appended.

**Symbol collisions** under multicall — both fixed in `playground/git/`:

- `scalar.c::load_builtin_commands` is a `die("not implemented")` stub that collides with git.c's real implementation once scalar.o is folded in. `playground/git/scalar-rename-load-builtin.patch` renames it to `scalar_load_builtin_commands`; help.c then resolves to git.c's real one (strict improvement).
- libidn2 (gnulib) exports a global `error` that collides with git's usage.c. Fix: `objcopy --localize-symbol=error libidn2.a` in the libidn2 derivation's postInstall — see `nix-lib/mingw-overlay/libidn2.nix` for the mingw side and `playground/git/flake.nix`'s `withLocalizedLibidn2` (threaded via `.override`, not as a top-level overlay — overlays at top level invalidate `pkgsBuildHost.stdenv` and force a gcc rebuild) for native.

After both, `LDFLAGS=-Wl,--allow-multiple-definition` is no longer needed anywhere.

**Static cascade** lives in `playground/git/flake.nix`'s `mkMingw` closure (wired at `packages.x86_64-linux.windows-x86_64`) — validated 2026-05-15, producing a 7.2 MB `git.exe` with zero non-system DLL imports:

- `cross = nix-lib.lib.mingwStaticCross pkgs` for the static-libs adapter.
- `curlSchannel = nix-lib.lib.mingwStaticBinary { ... }` — same shape as `unpins/curl` (`opensslSupport = false; scpSupport = false; libssh2 = null; brotliSupport = false; zstdSupport = false`) plus `--with-schannel` and `-DCURL_STATICLIB -DNGHTTP2_STATICLIB -DPSL_STATIC`.
- `gitMinimal.override { curl = curlSchannel; bash/gawk/gnused/gnugrep/coreutils = pkgs.X; }` to keep build-host tools native.
- **EXTLIBS gotcha**: the MINGW Makefile block accumulates `EXTLIBS += -lws2_32 -lntdll` plus multicall.patch's `EXTLIBS += $(CURL_LIBCURL) $(EXPAT_LIBEXPAT)`. A command-line `EXTLIBS=...` makeFlag **clobbers all of that**, so re-include everything explicitly, ordered consumer-before-provider for single-pass static linking:

  ```
  EXTLIBS=-lcurl -lexpat -lnghttp2 -lpsl -lidn2 -lunistring -liconv -lz -lws2_32 -lcrypt32 -lsecur32 -liphlpapi -lntdll -lbcrypt -ladvapi32
  ```

  `-lsecur32` provides Schannel's SSPI table (`InitSecurityInterfaceA`); `-liphlpapi` provides `if_nametoindex` that curl uses for interface scoping; `-lcrypt32`/`-lbcrypt` provide the cert validation + AEAD surface Schannel needs.

- **`NO_OPENSSL=YesPlease` + `USE_CURL_FOR_IMAP_SEND=YesPlease`** makeFlags: Schannel-curl means no openssl in tree, but git's `imap-send.c` references openssl symbols directly. The first prevents the openssl autoconf probe; the second routes IMAP TLS through curl (which uses Schannel).

**Runtime shell** is still required (`git-submodule`, `git-mergetool`, hooks). Same problem as Linux/Darwin, solved there by the dash-embed pattern in `playground/git/embed.patch`. For Windows, port the embed pipeline to cross-mingw (or use a cosmo dash blob). `playground/git/flake.nix`'s `multicallOverride { withEmbed = false; }` is the current mingw mode — ships the binary without embedded scripts; users of submodule/mergetool need a system shell until the embed port lands.

### coreutils

`pkgsCross.mingwW64.coreutils` (9.8 in nixos-25.11) fails in `lib/savewd.c` — gnulib uses `waitpid`, which Windows doesn't have. Shimming waitpid + the rest of the fork/signal surface would be open-ended.

Shipped path: native via the unpin-llvm engine (multicall self-fold). Windows via Cosmopolitan, wired through `windowsBuild = import ./cosmo.nix { inherit unpins-lib; }` in `unpins/coreutils/flake.nix` (per-binary recipe + patch live in `unpins/coreutils/{cosmo.nix,coreutils-cosmo.patch}`, the mega-side spec in its `multicallCosmo` block).

### Other transitive dead ends in 25.11 cross-mingw

- `libtheora` 1.1.1 (ld treats `.dll.def` as a linker script).
- `fftw` (gfortran-cross-wrapper broken — pulled by `speex`).
- `rav1e` (Rust toolchain too).

**No longer dead ends** (this list predates the provider-side `.pc` fixes above):

- `x265` — what looked like a "CMake error" was trap (A)'s dynamic-`-lgcc_s` leak; ships standalone (`unpins/x265`) and links into ffmpeg-Windows after the `.pc` sed.
- `svt-av1` — ships standalone (`unpins/svt-av1`) with LTO disabled (the [../static-linking.md](../static-linking.md) IR-archive trap). The `svt_av1_enc_init_handle` rename is an ffmpeg-version↔svt-version API mismatch, orthogonal to the cross build.

For ffmpeg, drop the genuinely-blocked codecs (see [../big-packages.md](../big-packages.md)).

## Why not overlays for per-package fixes

`pkgs.appendOverlays` works on linux runners (the build-host stays cached), but the same pattern on darwin invalidates `pkgsBuildHost.stdenv` and triggers ~30-60 min toolchain rebuilds. We use `drv.override` / `drv.overrideAttrs` inline in the consumer's `build` / `windowsBuild` closures instead — see [darwin.md](darwin.md) for the cascade details.

The exception is `nix-lib/mingw-overlay/<lib>.nix` (and the analogous `cosmo/`): those *are* applied as overlay pieces against the root `windowsPkgs`, from which both `pkgsCross.mingwW64` and `pkgsCross.cosmo` descend. Safe on mingw because `pkgsBuildHost` of the cross set is linux, so the overlay's `if isMinGW` gate skips the build side entirely.
