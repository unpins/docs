# Multicall binaries

When an upstream ships **several executables** (`e2fsprogs`, `util-linux`, `shadow`, `busybox`, `coreutils`, `srt`, `librist`), the one-pkg-one-bin rule means we fold them into a **single multicall binary**. It dispatches two ways, the **unified contract** across the whole catalog:

- **`argv[0]`** — invoked under an applet name (the canonical binary's basename is *not* that applet), it runs that applet. `lib.withAliases` embeds the applet names as the `unpin/aliases` entry in the binary's embedded `unpin/` ZIP (see [embedded-metadata.md](embedded-metadata.md)) so `unpin install` recreates these shims (symlinks on Linux/macOS, NTFS hardlinks on Windows). An alias is **locked to its argv[0] identity**: it ignores `--unpin-program` (below), so `ls --unpin-program=rm` runs `ls`, never `rm`.
- **`--unpin-program=NAME`** as the *first argument* of the bare/canonical binary selects an applet explicitly (coreutils' `--coreutils-prog=` convention, generalized). This is the **only** bare-binary selector — there is no positional `<pkg> <applet>` form — so a canonical name that is itself an applet (`zip`, `bzip2`) is never ambiguous with one of its siblings (`zip --unpin-program=zipnote` unmistakably runs `zipnote`).

This is distinct from the *whole-program-as-a-library* embed (e.g. dash inside git) in [patches.md](patches.md#symbol-collisions-when-linking-a-whole-program-as-a-library) — there the goal is to hide every symbol but one; here every program keeps its own entry point and the programs are peers.

## The dispatcher front-end (`lib.multicallDispatcherC`)

Both recipes end the same way: a tiny C `main` implementing the unified dispatch
contract. That front-end is **shared** — generate it with
`lib.multicallDispatcherC`, don't hand-copy it (the per-package copies had drifted
into a dozen subtly different dialects). It emits `multicall/dispatcher.c`:

```nix
# In the consumer's postBuild, AFTER writing multicall/apps.list:
#   printf '%s\n' "''${apps[@]}" > multicall/apps.list   # one applet name per line
# Invoke at COLUMN 0 (heredoc `CBODY` terminators must reach the shell at col 0):
${lib.multicallDispatcherC { inherit name; }}
$CC -O2 -c -o multicall/dispatcher.o multicall/dispatcher.c
```

Contract and canonical behaviour (all fixed in the helper — nothing to re-decide
per package):

- **Applet list** comes from `multicall/apps.list`, one name per line. The caller
  writes it (often the same list it uses to make the install symlinks).
- **Symbol naming**: each applet's C symbol is `tr -c 'A-Za-z0-9_' '_'` of its
  name, so a hyphenated applet (`srt-live-transmit`, `heif-enc`) maps to a legal
  identifier (`srt_live_transmit_main`, `heif_enc_main`). Your per-tool
  `objcopy --redefine-sym main=<sym>_main` rename **must** produce that same
  symbol (plain tools need no sanitiser; `srt`/`librist`/`heif` already rename to
  the sanitised form).
- **Alias path** (`argv[0]`): a basename that *is* an applet and is *not* the
  canonical name runs that applet directly. `--unpin-program` is not honored on
  this path — an alias is locked to its argv[0] identity.
- **Multitool path** (`--unpin-program=NAME`): the canonical name, a full path, or
  a renamed copy like CI's `smoke.exe` selects an applet with
  `--unpin-program=NAME` as the **first argument**. An unknown NAME errors on
  stderr and exits 1. There is **no positional `<pkg> <applet>` form** — so
  renamed binaries and the smoke test dispatch via the flag
  (`smoke.exe --unpin-program=<applet> …`), and a canonical name that is itself an
  applet is never ambiguous with a sibling.
- **Bare/unknown** prints the program list and exits 0 (a non-list junk arg prints
  a `--unpin-program=<name>` hint on stderr and exits 1), unless `defaultApplet` is
  passed: `lib.multicallDispatcherC { name = "libwebp"; defaultApplet = "cwebp"; }`
  makes a bare `libwebp -version` run `cwebp` (so `-version` smoke is clean). Used
  by `libwebp` (cwebp), `flac` (flac), `vorbis-tools` (ogg123), `opus-tools`
  (opusenc), and the Info-ZIP/bzip2 family below. A canonical name that is itself
  an applet (`zip`, `bzip2`) runs that applet on a bare invocation.

`defaultApplet` also covers the **"the package's own tool self-detects its
argv[0]"** pattern (`bzip2`/`unzip`/`zip`): put only the real `*_main` programs
in `apps.list`, and let the upstream tool handle its built-in argv[0] aliases via
the fallback. E.g. `bzip2` → `apps.list = bzip2 bzip2recover`, `defaultApplet =
"bzip2"`; the `bunzip2`/`bzcat` aliases are NOT applets, so they fall through to
`bzip2_main` with the original argv (argv[0] = `bunzip2`) and bzip2 self-detects
them. Same for `unzip` (applets `unzip funzip`, alias `zipinfo` → unzip), `zip`
(applets `zip zipnote zipcloak zipsplit`, `defaultApplet = "zip"`). With the
positional form gone, reaching a *sibling* applet of an applet-named canonical
binary is unambiguous: `zip --unpin-program=zipnote` runs `zipnote`.

Two parameters total: `name` and the optional `defaultApplet`. Everything that
used to vary per package (list source, sanitiser, fallback style) is now fixed.

**Two documented exceptions** that intentionally keep a hand-written dispatcher —
the only genuine divergences the generator does not model:

- `openjpeg`: a bare invocation prints a version banner and exits **0**. Every
  `opj_*` tool exits 1 even on `-h`, so no `defaultApplet` gives a clean smoke;
  the banner is the smoke target.
- `libvpx`: `vpxenc`/`vpxdec`'s shared `tools_common.c` calls `usage_exit()` by
  name; the dispatcher carries a per-tool function-pointer trampoline so each
  tool keeps its **own** usage banner (more precise than the aom-style
  "one global + localize the rest", which would show the template's banner).

Reference: `unpins/{aom,avif,jxl,heif,srt,librist,rtmpdump,libwebp,flac,
vorbis-tools,opus-tools,jpeg-tools,bzip2,unzip,zip}` all call it; `unpins/openjpeg`
+ `unpins/libvpx` are the exceptions (plus `unpins/xmllint`, whose tools export
`xmllintMain`/`xmlcatalog_main` rather than `<applet>_main` and use a committed
`dispatcher.c`).

### Recipe-A variant — `lib.multicallTableDispatcherC`

The `ld -r` family (`e2fsprogs`, `util-linux`, `shadow`, `findutils`,
`procps-ng`) needs a **name→function table that is many-to-one** — e2fsprogs
maps `mkfs.ext2/3/4` → `mke2fs_main`, `e2label`/`findfs` → `tune2fs_main` — so
the symbol can't be derived from the applet name. They use the sibling generator
`lib.multicallTableDispatcherC { name, defaultApplet ? null }`, whose contract is
a TSV the caller writes first:

```
multicall/applets.list:   <applet-name>\t<fn-base>      # C symbol is <fn-base>_main
```

Aliases are extra rows pointing at the same `<fn-base>`. It implements the same
dispatch contract as `multicallDispatcherC` (alias path on `argv[0]`,
`--unpin-program=NAME` selector on the canonical/renamed binary, no positional
form), plus it strips a libtool `lt-` argv[0] prefix and an unconditional `\\` dir
separator (cosmo APE argv[0] can carry one and `_WIN32` isn't defined for cosmo).
`defaultApplet` here is an `<fn-base>` (e.g. procps-ng's `src_ps_pscommand`,
findutils' `find`), so a bare `--version` or a renamed binary routes to that tool.
A renamed binary's smoke selects its applet with
`smoke.exe --unpin-program=<applet>`.

Two recipes, by how the upstream builds the programs.

## Recipe A — `ld -r` relocatable merge (autotools/Make upstreams)

For `e2fsprogs` / `util-linux` / `shadow` / `busybox`, where the programs are built from object files in a Make tree. Partially link each program's objects into one relocatable object, prefix-rename its symbols so siblings don't collide, then archive all of them and link once with a dispatcher.

```bash
# Per program: combine its objects, redefine its `main` (and any global it
# shares with a sibling) to a unique prefix.
$LD -r prog/*.o -o prog_combined.o
$OBJCOPY --redefine-sym main=prog_main prog_combined.o
$AR rcs libprog.a prog_combined.o
```

Landmines (each cost real time — see auto-memory `feedback_post_link_multicall_recipe`):

1. **Parse the applet list with a single-pass `awk`, not a `grep -v` pipeline.** A `grep -v` that matches nothing exits non-zero and aborts the phase under `set -e`.
2. **Guard the empty-symbol case.** An `objcopy` with an empty redefine list is a silent no-op that masks a parsing bug.
3. **`_moveSbinToBin` runs *after* `postInstall`.** `lib.withAliases` harvests `bin/` in its own `postInstall`, which is *before* fixup's sbin→bin merge — so applets that land in `sbin` (e.g. `mkfs.*`, `agetty`) miss the alias harvest. Merge sbin→bin in your own `postInstall` *before* `withAliases` wraps the drv. See `feedback_with_aliases_sbin_merge_trap`.
4. **Reuse the Makefile's own `-l` variables, don't hardcode them.** Parse `$(LDLIBS)` / `$(LIBS)` from the generated Makefile; hardcoded `-lfoo` lists drift across versions.
5. **`linux-i686` needs `--start-group`.** Its libc pulls extra cross-references the single-pass linker won't resolve left-to-right.
6. **Mach-O leads C symbols with `_`.** Read the prefix once from the first object (`nm --defined-only | grep _main`) and apply it to every `--redefine-sym`.
7. **`llvm-objcopy` `--redefine-sym` is a no-op on Mach-O `DATA`/`BSS` symbols.** For the whole-program-localize variant on Mach-O, use `ld -r -exported_symbols_list` instead of `--localize-symbol`.
8. **automake emits `PROGRAMS` before `am__EXEEXT_N`.** Resolve `$(am__EXEEXT_N)` references in an `END {}` block, not inline (shadow's Makefile).

Reference: `unpins/e2fsprogs`, `unpins/util-linux`, `unpins/shadow`, `unpins/busybox`.

## Recipe B — reuse the build system's resolved link line (CMake/meson upstreams)

For `srt` (CMake/C++) and `librist` (meson/C), where the upstream already produces fully-linked app executables. Don't reconstruct the link by hand — **reuse the exact link line the build system resolved** (correct compiler, flags, library group, per-target deps), splice in the other apps' objects + a dispatcher, and **iteratively** relink, renaming whatever the linker reports as a duplicate.

Get the resolved link line:

- CMake: `cat CMakeFiles/<app>.dir/link.txt`
- meson: `ninja -t commands <target> | tail -1`

Then:

1. **Rename each app's `main` → `<app>_main`** up front (the one clash known a priori; the dispatcher needs distinct entry points anyway).
2. **Pick a *template* app whose object set is a superset of the shared helpers**, reuse its link line verbatim, and splice in only each *other* app's own translation-unit object. This matters when the build compiles shared helpers **once per app** (meson does: `tools/<app>.p/oob_shared.c.o`) rather than into a shared OBJECT library (srt's CMake does). Renaming a shared symbol the naïve way would break it — the definition lives in `oob_shared.c.o` but the references live in `<app>.c.o`, different objects. Splicing only the template's copy sidesteps that; the only clashes left are `main` and globals an app defines in its *own* `.c` (def + refs in the same object → a per-app `--redefine-sym` stays self-consistent).
3. **Trust the linker, not `nm`, to find clashes.** On COFF, `nm` reports COMDAT defs (typeinfo, vtables, `.refptr` thunks) as strong `R`/`T`, indistinguishable from real clashes, while the linker merges them silently. Loop: link → scrape `multiple definition of` / `duplicate symbol` from stderr → `--redefine-sym` each in every app that defines it → relink. Converges in 1–2 passes for C, a few for C++.
4. **Map the reported name back to the raw `nm` symbol before `objcopy`.** GNU `ld` prints mangled names with `-Wl,--no-demangle` (objcopy-ready); `ld64` *always* demangles and has no flag to stop it, so match the reported name against both the raw `nm` symbol and its `c++filt` form (strip the Mach-O leading `_` first).
5. **meson object layout differs on mingw:** `tools/<app>.exe.p/<app>.c.obj` (the `.exe` rides in the dir name, `.obj` not `.o`). Probe for it rather than assuming the unix `tools/<app>.p/<app>.c.o`.
6. **mingw `gcc` auto-appends `.exe`** to the link output; normalize to the suffixless name `installPhase`/`withAliases` expect, then let the Windows `postFixup` re-add `.exe` *after* the alias embed (symlinks are gone by then, nothing dangles).
7. **Force the C++ runtime static on mingw** (`-static -static-libgcc -static-libstdc++`) and on darwin (`-nostdlib++ libc++.a libc++abi.a`, see [platforms/darwin.md](platforms/darwin.md)) so the multicall `.exe`/binary carries no `libstdc++-6`/`libgcc_s`/`libc++.1` dependency — same single-binary policy as a normal package. This holds even when the *apps* are C (`aom`): if the linked `.a` carries C++ objects, the link still pulls the C++ runtime.
   - **mingw `std::thread` caveat (`jxl`):** with the `mcf` GCC thread model, `std::thread`/`std::mutex` resolve through **libmcfgthread**, which `-static-libstdc++` does *not* cover (it's a separate lib, and the driver appends an implicit dynamic `-lmcfgthread` last). The `.exe` then imports `libmcfgthread-2.dll`. Fold it explicitly: `-Wl,-Bstatic -lmcfgthread -Wl,-Bdynamic`, with `windows.mcfgthreads` on the link path. See [platforms/mingw.md](platforms/mingw.md), auto-memory `feedback_mingw_mcfgthread_stdthread_static_fold`.
   - **Heavy-C++ caveat (`heif`):** when the folded archives are heavy C++ (iostream, exceptions, multiple C++ codec libs), the runtime-static recipe above is necessary but not sufficient: on **mingw** the *combined* link trips a binutils 2.44 PE-COMDAT bug → drive it with lld (`-fuse-ld=lld`); on **darwin** the static libc++'s weak symbols get coalesced with the system libc++ at load → unexport the whole libc++/libc++abi surface (`-Wl,-unexported_symbols_list`), or it crashes at runtime on macOS 15 while `otool -L` still looks clean. Both detailed in [platforms/mingw.md](platforms/mingw.md) / [platforms/darwin.md](platforms/darwin.md), auto-memory `project_unpins_heif_wip`.
8. **Splice the sibling apps' role-specific OBJECT-lib members the template's link line omits.** When the template app's link doesn't pull an OBJECT lib another app needs (`aomenc`'s link lacks the `aom_decoder_app_util` objects `aomdec` needs), find and splice them: `find . -path "*<objlib>.dir/*.$oext"`. Make spliced objects absolute if the link runs from a build subdir (the `link.txt` paths are relative to it — e.g. libjxl builds tools under `tools/`).

The dispatcher is a tiny C file implementing the unified contract: `basename(argv[0])` (with `.exe` stripped and `\\` handled on Windows) → the matching `<app>_main` on the alias path, plus a `<pkg> --unpin-program=<applet> [args]` selector so the bare binary stays callable (no positional form).

Reference: `unpins/srt/multicall.nix` (CMake/C++), `unpins/librist/multicall.nix` (meson/C), `unpins/avif` + `unpins/jxl` + `unpins/aom` (CMake image/video codec CLIs — `aom` adds the app-provided-hook localize and OBJECT-lib splice; `jxl` the subdir-build link.txt and mingw `std::thread` fold), `unpins/heif` (heaviest C++ chain — mingw lld for the combined link + darwin libc++ symbol unexport). All invoked as `import ./multicall.nix { lib = pkgs.lib // unpins-lib.lib; } { ... }` from the consumer flake.

## Symbol-collision tool choice

`objcopy --redefine-sym OLD=NEW` rewrites the definition **and** every reference *within the object(s) you run it on*, keeping them self-consistent — this is the correct tool for the common case. It is the **wrong** tool when the reference lives in a **third object you must not rename**; reach for `--localize-symbol` there instead. Two such cases:

- **Embedding a whole program as a library** (dash inside git): localize *every* symbol but one, so nothing outside sees the embedded program's symbols. See [patches.md](patches.md#symbol-collisions-when-linking-a-whole-program-as-a-library).
- **App-provided hooks in a multicall** (`aom`'s `aomenc`/`aomdec`): each app *defines* a hook (`usage_exit`, `exec_name`) that the **shared** helper TU (`tools_common.c`, compiled once into a common OBJECT lib) *calls by name*. Renaming the hook in *both* app objects leaves that shared reference undefined; renaming in neither gives `multiple definition`. Fix = **one global + the rest local**: keep the definition in exactly one app (the template whose link line you reuse) and `--localize-symbol=<sym>` it in every other app object. The shared TU binds to the surviving global; each other app's own calls bind to its now-local copy — one global + N locals never clashes. Tradeoff: a non-template app's hook-mediated output (e.g. a usage banner printed via the shared `die()`) shows the template's text — cosmetic; dispatch and exit codes are correct. (`main` is still renamed-in-all *before* this pass — the dispatcher needs distinct `<app>_main`.)

  ```bash
  kept=0                                    # detect clashes from the linker, then:
  while read app; do
    raw=$($NM --defined-only "${OBJ[$app]}" | awk -v s="$sym" '$3==s{print $3;exit}')
    [ -n "$raw" ] || continue
    if [ "$kept" = 0 ]; then kept=1; continue; fi   # first definer stays global
    $OBJCOPY --localize-symbol="$raw" "${OBJ[$app]}"
  done
  ```

  Reference: `unpins/aom/multicall.nix`. See auto-memory `feedback_multicall_localize_app_provided_hooks`.
