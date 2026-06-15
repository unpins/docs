# Dynamic-link policy

unpins ships **standalone binaries**. The user drops the file into `~/.local/bin` (or wherever) and runs it — no second file, no installer, no DLL closure.

The only dynamic dependencies allowed in a shipped artifact are libraries the host OS itself provides. Every other dependency is embedded statically.

## Per-OS allow-list

### Linux

Statically link everything. The binary must report **`statically linked`** to `file(1)`.

We use `pkgsStatic` (musl). Glibc is rejected — its static link assumes the same kernel/glibc version at runtime, which is not portable across distros.

### macOS

Allowed dynamic loads:

- `/usr/lib/libSystem.B.dylib`
- `/System/Library/Frameworks/*`
- `/usr/lib/libobjc.A.dylib` — the Objective-C runtime is required by any framework, and Apple disallows linking it statically.

Other `/usr/lib/*.dylib` (`libresolv`, `libiconv`, `libxml2`, `libc++`, etc.) are de facto stable but **not** in Apple's ABI contract. Embed them statically.

CI enforces this via `otool -L` against the allow-list.

### Windows

The Windows artifact is always a single `x86_64` PE `.exe`, whether built via mingw or cosmo — the cosmo path apelinks `-V 4` to a Windows-only PE in `fixupPhase` and ships *that*, never the APE fat binary (see [platforms/cosmocc.md](platforms/cosmocc.md) and the [Cosmopolitan caveat](#cosmopolitan-caveat) below).

Allowed dynamic loads: only DLLs under `%WINDIR%\System32` — `KERNEL32.dll`, `ucrtbase.dll` / `msvcrt.dll`, `WS2_32.dll`, `USER32.dll`, `ADVAPI32.dll`, `SHELL32.dll`, `SHLWAPI.dll`, `GDI32.dll`, etc.

CI applies two checks (`action-build/.github/workflows/build.yml`):

1. **No companion `*.dll` in `result/bin/`.** Any `.dll` file alongside `<pkg>.exe` is rejected — `find result/bin -maxdepth 1 -type f -name '*.dll'` must be empty. The MinGW `win-dll-link.sh` setup hook auto-copies imported third-party DLLs next to the `.exe`; with a fully static link this hook becomes a no-op and the directory stays clean.
2. **No `lib*.dll` import.** The check is `grep -iE '^lib.*\.dll$'` over `objdump -p`'s `DLL Name` lines. The convention is that third-party DLLs are named `libfoo-N.dll` (lowercase + version suffix) and Microsoft's system DLLs use uppercase names.

That means **no companion DLLs** alongside the `.exe`, including `libgcc_s_seh-1.dll`, `libstdc++-6.dll`, `libwinpthread-1.dll`, or anything from `/nix/store/`. Use `-static-libgcc -static-libstdc++` and `LDFLAGS=-all-static`.

## When the upstream build picks up a forbidden library

Patch it out in the consumer's `build` / `windowsBuild` closure (or in `nix-lib/{native,mingw}-overlay/<lib>.nix` if the offender is a transitive lib dep). The binary must satisfy the policy; don't relax the verifier.

Examples:

- `tmux`'s `configure.ac` links `-lresolv` on darwin (for `b64_ntop`). darwin's `libresolv.9.dylib` is not in Apple's allow-list. Solution: a `postPatch` inside `tmux/flake.nix`'s `build` closure removes the `-lresolv` probe; tmux falls back to its bundled `compat/base64.c`.
- `file`'s `libgnurx` on mingw ships only a DLL + import library. The nix-store-supplied `libgnurx.a` is a symlink to the import lib, so even with `-all-static` the result imports `libgnurx-0.dll`. Solution: rebuild `regex.o` into a real static archive via `ar rcs` in the consumer flake's `windowsBuild`.
- See [platforms/mingw.md](platforms/mingw.md) for the libidn2 / libpsl / libunistring / libiconv chain that powers curl, wget, gnupg.

## Cosmopolitan caveat

Packages built with the Cosmopolitan toolchain (`cosmocc` 4.x — see [platforms/cosmocc.md](platforms/cosmocc.md)) produce PE binaries with an **empty import table** — they call `ntdll.dll` directly via syscall numbers. CI's `grep -iE '^lib.*\.dll$'` import check passes by omission, but `ntdll` is stable de facto since NT 4.0 and *not* in the Microsoft ABI contract.

We accept this trade-off for packages whose mingw cross is infeasible because of upstream POSIX assumptions (fork/waitpid/signals). `coreutils` is the first catalog package on the cosmo path (via `coreutils/cosmo.nix` sidecar invoked from `windowsBuild`); `bash`, `dash`, `findutils`, `gawk`, `links` now also ship via this pattern. `git` remains in `playground/` until its cosmo recipe is stable.

## Why the rule exists

unpins distributes single-binary programs meant to be dropped into a single directory. Shipping companion DLLs/dylibs/sos breaks that model — users would manage a directory of files per package, and `unpin`'s install/uninstall path assumes one artifact per binary.

Same rule already applied to Linux (musl) and macOS (libSystem-only) since the MVP; Windows joined when mingw cross builds were added. The user has explicitly rejected the "ship the DLLs in the same tarball" pattern (MSYS2 / Git-for-Windows style).
