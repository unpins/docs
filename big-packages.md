# Big packages (ffmpeg-class)

Packages with large dependency graphs — `ffmpeg` is the canonical case — don't fit the one-liner `pkgs.pkgsStatic.<name>` flow. Both the native and Windows builds need from-source `mkDerivation` with hand-curated static deps.

This page documents the playbook validated during the original port (ffmpeg 8.0 → 67 MB ELF static Linux + 71 MB PE32+ Windows, zero non-system DLLs). The shipping `ffmpeg/flake.nix` has since grown well past it — more codecs, the unpin-llvm engine, all CI targets green — so read this as method (audit deps first, per-build-system static knobs, cache-aware overrides), and the shipped flake as the current state.

## Two key insights

1. **`-static` ldflag picks `.a` over `.dll.a` automatically.** Don't fight to forbid the shared lib — just ensure `.a` exists alongside, then `ld` in static mode picks it.

2. **Cache-aware: don't override what `pkgsStatic` already does.** Adding `--disable-shared` to a `pkgsStatic` lib changes its derivation hash → cache miss → uncached rebuild. `pkgsStatic` libs are already static-only; use them as-is. Only override for non-static contexts (cross-mingw default = shared).

## Pre-flight: per-build-system audit

Run **before** writing the flake. Use the *flake's* nixpkgs (not the global `<nixpkgs>`) for path consistency.

```bash
# Build matrix
for lib in opus vorbis ogg lame xvidcore zimg xz bzip2 zlib libiconv x264 dav1d svt-av1; do
  out="/tmp/lib-${lib}"; rm -f "$out"
  nix build --impure --expr "(import <nixpkgs> { config.allowUnsupportedSystem = true; }).pkgsCross.mingwW64.${lib}" --out-link "$out" 2>&1 >/dev/null &
done; wait

# Detect build system
nix eval --impure --json --expr '
  let pkgs = import <nixpkgs> { config.allowUnsupportedSystem = true; };
      cross = pkgs.pkgsCross.mingwW64;
      detect = lib:
        let names = map (x: x.pname or x.name or "") ((cross.${lib}.nativeBuildInputs or []) ++ (cross.${lib}.buildInputs or []));
        in if builtins.any (s: builtins.match ".*cmake.*" s != null) names then "cmake"
           else if builtins.any (s: builtins.match ".*meson.*" s != null) names then "meson"
           else "autotools/other";
  in builtins.listToAttrs (map (l: { name = l; value = detect l; }) [ /* lib list */ ])'

# Inventory .a files in each output
for lib in /* list */; do
  for sub in "" "-lib" "-bin" "-dev"; do
    p="/tmp/lib-${lib}${sub}/"  # trailing slash is critical
    [ -L "${p%/}" ] && find "$p" -name '*.a' ! -name '*.dll.a'
  done
done
```

**Multi-output gotcha:** many libs split `out`/`lib`/`dev`. The `.a` may be in the `lib` output (e.g. `cross.lame.lib`). Use `nix eval --raw .lib.outPath` to find them, or check all outputs of a lib via `.outputs`.

## Per-build-system static knob (validated)

```nix
# Autotools: --enable-static + --disable-shared. dontDisableStatic stops
# nixpkgs' strip phase from removing the .a.
staticOnlyAuto = drv: drv.overrideAttrs (old: {
  dontDisableStatic = true;
  configureFlags = (old.configureFlags or [])
    ++ [ "--enable-static" "--disable-shared" ];
});

# Meson: default_library=static (NOT 'both' if pkgsStatic toolchain
# can't link shared objects — crtbeginT.o issue).
staticOnlyMeson = drv: drv.overrideAttrs (old: {
  mesonFlags = (old.mesonFlags or []) ++ [ "-Ddefault_library=static" ];
});

# CMake: BUILD_SHARED_LIBS=OFF. Some projects have their own option
# (openapv: OAPV_BUILD_SHARED_LIB) that BUILD_SHARED_LIBS doesn't gate.
# Inspect CMakeLists for the right knob.
staticOnlyCmake = extraFlags: drv: drv.overrideAttrs (old: {
  cmakeFlags = (old.cmakeFlags or []) ++ [ "-DBUILD_SHARED_LIBS=OFF" ] ++ extraFlags;
});
```

## Cache-aware `mkCodecLibs` factory

```nix
mkCodecLibs = pkgs:
  let
    isStatic = pkgs.stdenv.hostPlatform.isStatic or false;
    # Identity in static contexts (preserves cache.nixos.org hit)
    keepAuto  = if isStatic then (drv: drv) else staticOnlyAuto;
    keepMeson = if isStatic then (drv: drv) else staticOnlyMeson;
    keepCmake = extras: if isStatic then (drv: drv) else staticOnlyCmake extras;
    keepZlib  = if isStatic then (drv: drv) else (drv: drv.override { shared = false; });
  in
  rec {
    zlib       = keepZlib pkgs.zlib;
    bzip2      = keepAuto pkgs.bzip2;
    xz         = keepAuto pkgs.xz;
    libiconv   = keepAuto pkgs.libiconv;
    libogg     = keepCmake [] pkgs.libogg;  # libogg-1.3.6+ is cmake
    libvorbis  = if isStatic then pkgs.libvorbis
                 else keepAuto (pkgs.libvorbis.override { inherit libogg; });
    libopus    = keepMeson pkgs.libopus;
    lame       = keepAuto pkgs.lame;
    zimg       = keepAuto pkgs.zimg;
    # x264 always patched (its .pc has -DX264_API_IMPORTS hardcoded by
    # nixpkgs, breaks ffmpeg's static link probe).
    x264       = pkgs.x264.overrideAttrs (old: {
      configureFlags = (old.configureFlags or [])
        ++ lib.optionals (!isStatic) [ "--enable-static" "--disable-shared" "--enable-pic" ];
      postFixup = (old.postFixup or "") + ''
        for d in "$dev" "$out"; do
          pc="$d/lib/pkgconfig/x264.pc"
          [ -f "$pc" ] && sed -i 's| -DX264_API_IMPORTS||g' "$pc" || true
        done
      '';
    });
    dav1d      = keepMeson pkgs.dav1d;
  };
```

## Consumer (ffmpeg) wiring

Both native and Windows use `mkDerivation` from-source — **not** `pkgsStatic.ffmpeg-headless`. That variant's uncullable codecs (`openapv`, `ocl-icd`, `libtiff`, `libsndfile`) add cascading pkgsStatic build issues.

### Universal flags

```
--pkg-config=pkg-config --pkg-config-flags=--static --extra-ldflags=-static
--enable-static --disable-shared
--disable-doc --disable-htmlpages --disable-manpages --disable-podpages --disable-txtpages
--disable-debug --disable-stripping
--enable-gpl --enable-version3 --enable-runtime-cpudetect --enable-network
--disable-ffplay --enable-ffmpeg --enable-ffprobe
--enable-{zlib,bzlib,lzma,iconv,libx264,libdav1d,libopus,libvorbis,libmp3lame,libzimg}
```

### Native (pkgsStatic)

- `--cross-prefix=${pkgs.pkgsStatic.stdenv.hostPlatform.config}-` — cc-wrapper only ships prefixed bins like `x86_64-unknown-linux-musl-gcc`; no plain `cc`.
- `--host-cc=${pkgs.stdenv.cc}/bin/cc` — build-platform glibc gcc, used for build-time helper progs.
- `--enable-cross-compile` — pkgsStatic counts as cross from ffmpeg's POV.
- `--target-os=linux --arch=x86_64`.
- **No `ERR` trap in `configurePhase`** — ffmpeg's configure handles probe failures internally; an `ERR` trap intercepts internal non-zero exits and breaks the build (e.g., `stdbit.h` C23 probe fails on musl, configure handles it, trap propagates).

### Windows (pkgsCross.mingwW64)

- `--cross-prefix=x86_64-w64-mingw32-`.
- `--host-cc=${pkgs.stdenv.cc}/bin/cc`.
- `--enable-cross-compile --target-os=mingw64 --arch=x86_64`.
- `--disable-w32threads --enable-pthreads` (winpthread).

Always patch `configure` to remove the unconditional `-DX264_API_IMPORTS` injection:

```bash
sed -i '/X264_API_IMPORTS/d' configure
```

Strip in `installPhase`: `${triple}-strip $out/bin/*`.

## Shell-quoting gotcha (Nix)

If you split universal and platform flags into separate Nix variables and interpolate the universal one mid-command, end the interpolation block with a backslash:

```
./configure ... \
  ${ffmpegConfigureCommon} \   # MUST end with \
  --enable-pthreads
```

Without the backslash bash sees `--enable-pthreads` as a **new command** ("command not found"). Either end the common block with `\` or put platform flags **before** the interpolation.

## Blocked in nixpkgs cross-mingw (as of the original port)

Features dropped in the Windows configure back then. **Two were later unblocked** — `x265` (the "CMake error" was the dynamic-`-lgcc_s` `.pc` leak, trap A in [platforms/mingw.md](platforms/mingw.md)) and `svt-av1` (LTO-off + the API-rename was an ffmpeg↔svt version mismatch); both ship standalone and link into ffmpeg-Windows now. Still blocked:

- `gnutls` → `unbound` → `bash` (bash-cross broken — see [platforms/mingw.md](platforms/mingw.md)).
- `libssh` → `libsodium` (the `mingw-no-fortify.patch` is already applied; another issue blocks it).
- `libtheora` 1.1.1 (ld treats `.dll.def` as linker script).
- `fftw` (gfortran-cross-wrapper broken — pulled by `speex`).
- `rav1e` (Rust toolchain).

## Result of the original port (ffmpeg 8.0)

|                   | Native (musl)               | Windows (mingw)                              |
| ----------------- | --------------------------- | -------------------------------------------- |
| `ffmpeg` | 33 MB stripped | 36 MB stripped |
| `ffprobe` | 33 MB stripped | 35 MB stripped |
| Total bundle | 67 MB | 71 MB |
| Type | ELF static | PE32+ |
| Runtime deps | Linux kernel only | KERNEL32, msvcrt, GDI32, USER32, SHELL32, SHLWAPI, OLE32, OLEAUT32, CRYPT32, ncrypt, Secur32, WS2_32, AVICAP32, ntdll (all system) |
| Codecs | x264 (H.264 enc), dav1d (AV1 dec), libopus, libvorbis, libmp3lame, libzimg, zlib/bz/lzma/iconv, plus ffmpeg built-ins (AAC enc, MJPEG, etc.) | |

Reference implementation: `ffmpeg/flake.nix` (the shipping package — the playground POC graduated).

## Static GTK2 (gvim case)

A separate worked example: pkgsStatic GTK2 on musl builds end-to-end (~20 MB hello-world) with ~6 overrides + 2 small patches. Lives in `playground/static-gtk2-recipe/`, consumed by `gvim/` for the Linux build.

### Overrides

1. **`graphite2`** via overlay: strip `.la` files in `postFixup`. nixpkgs' static graphite2 ships an `.la` that points to `libgraphite2.so` (doesn't exist); libtool obeys the `.la` over the `.a`. Delete the `.la`.

2. **`at-spi2-core` `atk_only=true`** — meson flag to build *only* the libatk stub without the at-spi/dbus daemon glue. GTK2 only needs libatk symbols at link time; the bus launcher (which would need dbus + dconf at runtime) is unnecessary. Single biggest unlock.

3. **`at-spi2-core`** override: nullify `dconf`, `gsettings-desktop-schemas`, `gobject-introspection`; set `postFixup = ""` (upstream `postFixup` references `${lib.getLib dconf}` which would force-evaluate dconf).

4. **`gtk2`** override: nullify `gobject-introspection` (only used for `.gir`/`.typelib`, not needed for C link); set `cupsSupport = false` (cups propagates linux-pam, which is dlopen-by-design and unbuildable under musl-static).

5. **`gtk2`** `postConfigure`: replace `perf/Makefile` with a no-op. The `perf/testperf` benchmark generates its own copy of marshalers; under static link the symbols collide with `gtk/gtkmarshalers.o`.

6. **`gtk2`** configure: `--with-included-loaders=yes --with-included-immodules=yes` to bundle pixbuf loaders and immodules into the binary instead of trying to `dlopen` them at runtime.

### Patches

- `gtk2-static-mixed-deps.patch` (3 lines): early-return FALSE in `_gtk_module_has_mixed_deps()` when `g_module_open(NULL)` returns NULL. Without it `gtk_init()` prints two `GModule-CRITICAL` warnings on every run.
- `gtk2-static-silence-dlopen.patch`: demote `g_message` / `g_warning` to `g_debug` in `load_module()`, `gtk_theme_engine_load()`, and the engine symbol-lookup paths. Without it, the host desktop's `GTK_MODULES` env + `~/.gtkrc-2.0` (Adwaita, pixmap theme engines) each spam ≥1 warning per `gtk_init()`.

### vim-full configure overrides for static GTK2

When building `pkgsStatic.vim-full.override { guiSupport = "gtk2"; gtk2-x11 = <static-gtk2>; ... }`, three nixpkgs configure flags need filtering via `overrideAttrs`:

1. **`--disable-gtk_check` / `--disable-gtk2_check`** — nixpkgs disables both to prevent vim's autodetector from accidentally picking up shared GTK from the host. With a deliberate static gtk2 in `gtk2-x11`, that's exactly what we want. Without filtering, vim's configure emits `checking --enable-gui argument... no GUI support` and silently falls back to console-only.

2. **`--disable-xsmp` / `--disable-xsmp_interact`** — vim's link pulls in `libXt.a`, which references `SmcRequestSaveYourselfPhase2` / `SmcSaveYourselfDone`. With xsmp disabled, vim doesn't `-lSM -lICE` and the link fails. Re-enabling xsmp makes vim's configure add SM libs.

3. **`ac_cv_have_x=have_x=yes ac_x_includes= ac_x_libraries=`** (cache override) — vim's `AC_PATH_X` runs `xmkmf` then probes `/usr/X11R6/lib`; none of which exist in a nix store. Cache override bypasses the heuristic; `-I`/`-L` paths come from stdenv via `buildInputs`.

Why GTK3 is harder (and not used): dconf propagated directly from gtk3 transitive deps, gobject-introspection deeper in the chain (gdk-pixbuf-static needs g-i, gtk2 doesn't), wayland-scanner + gsettings-desktop-schemas in the eval chain. GTK2 has every widget gvim needs.

Reference implementation: `gvim/flake.nix`.
