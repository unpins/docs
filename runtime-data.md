# Packages with runtime data

Some programs need files beyond the executable at runtime: `vim` needs its
`share/vim/<ver>/` runtime tree (syntax, ftplugin, doc, …), `gvim` the same,
`file` needs its compiled magic database (`magic.mgc`). unpins ships these
**inside the binary** — no companion file, no extract-on-first-run — so the
single-binary contract holds. A separate `.tar.zst` next to the binary
(`package_data`) still exists for the rare case embedding can't cover, but it is
**off by default**; embedding is the norm.

There are two embedding patterns, picked by how the program consumes the data.

## Pattern 1 — compiled-in blob (one file behind a load-from-buffer API)

When the data is a single blob the program loads through a library call, compile
it straight into the binary and feed the in-memory buffer to that call. Best when
upstream already has a "load from a buffer" entry point.

`file` is the worked example (`file/flake.nix` + `file/file-embed-magic.patch`):

1. Let the normal build generate `magic/magic.mgc` from the ASCII `Magdir/`
   tables.
2. A `postBuild` step writes a C header with
   `xxd -n magic_mgc -i magic/magic.mgc > src/embedded_magic.h`, then relinks the
   binary.
3. The patch wires `file.c::load()` to feed that blob to `magic_load_buffers()`
   when the user passed no `-m` and set no `$MAGIC`; explicit `-m` / `$MAGIC`
   still go through `magic_load`, so power users are unaffected.

The blob is embedded **raw** (not gzip): the release asset is already zstd-19
compressed, and zstd over a pre-gzipped blob recovers almost nothing (`file`'s db
is ~8.5 MB either way).

## Pattern 2 — runtime tree in the embedded ZIP + in-tool VFS (a tree opened by path)

When the program opens many files by path at runtime (a whole runtime tree),
ship the tree inside the binary's **single embedded ZIP** — the same
container that carries `unpin/aliases` and `unpin/man/*`
([embedded-metadata.md](embedded-metadata.md)) — and add a tiny virtual
filesystem that intercepts the program's own file calls for a marker path and
serves them from that ZIP. The VFS core is shared
(github:unpins/unpin-vfs, vendored per package) and runs in **self-EOF mode**
(`-DUNPIN_VFS_SELF`): `unpin_vfs_init()` locates the running executable
(`/proc/self/exe`, `_NSGetExecutablePath`, `GetModuleFileNameW`), opens it
read-only and reads the ZIP straight off its EOF — the absolute, file-adjusted
offsets the embed writes mean the whole file parses as one archive. No
`.incbin`/`blob.S` section, no relink when only data changes; the `unpin/` and
`.unpin/` namespaces are hidden from VFS lookups and listings.

`vim` is the worked example (`vim/flake.nix`; vendored VFS sources `vfs.c`,
`vfs.h`, `miniz.c`, `unpin_zstd.c` + `zstddeclib.c`, glue `unpins_init.c`). The
build:

1. `injectVfs` copies in the VFS core + glue. `unpins_init()` is injected right
   after `mch_early_init()` in `main.c`; on Linux the libc file calls are
   rerouted at link time (`ld --wrap`), on macOS by `llvm-objcopy
   --redefine-sym` + relink, and on Windows `mch_open` / `mch_fopen` (real
   wide-char wrapper functions) get a virtual-path dispatch patched in at
   entry.
2. nix-lib's `withRuntimeData` stages the `share/vim/vim<NN>` tree CONTENTS as
   the ZIP root in `postFixup` (after strip) and the shared embed accumulator
   repacks the binary's one ZIP — runtime entries as zstd method-93 against
   the shared `.unpin/zdict` dictionary, smaller than the old deflate blob.
3. `postInstall` removes the on-disk `share/vim/vim*` — the tree now lives only
   in the binary.

The VFS sources live in the package repo (copy `vim/`'s as a starting point);
miniz is built with `-DMINIZ_NO_*` so only the inflate path is linked, plus
`-DMINIZ_USE_ZSTD` with the vendored decompress-only `zstddeclib.c`.

> The runtime tree and the `unpin/*` metadata (aliases + man pages, see
> [embedded-metadata.md](embedded-metadata.md)) share the binary's ONE
> embedded ZIP but never mix: `unpin/*` and `.unpin/*` are unpin's namespaces,
> read by the `unpin` CLI and hidden from the package's own VFS; everything
> else is the runtime tree, served by the VFS and ignored by unpin's reader.
> (gvim/perl/biber still embed their tree the old way — a private blob linked
> in as a section via `.incbin` — until they migrate to self-EOF.)

## Fallback — companion archive (`package_data`, opt-in)

`package_data` is `false` by default in `mkStandaloneFlake`. Set it `true` only
for a package that genuinely can't embed its data. action-build then attaches
`<pkg>-<tag>-data.tar.zst` (built from `result/share/`, gated on it existing) to
the GitHub release, and `unpin install <pkg>` extracts it into the version
directory:

```
~/.local/share/unpin/<owner>/<pkg>/<tag>/
├── bin/<pkg>
└── share/…                       # contents of the data archive
```

`~/.local/bin/<pkg>` symlinks to `bin/<pkg>`; on Windows the layout collapses into
`%LOCALAPPDATA%\unpin\packages\<owner>\<pkg>\<tag>\` plus a `<pkg>.exe` NTFS
hardlink in the PATH dir. On
disk the binary must then find that data **relative to itself**, not via the
`/nix/store/...` path baked at build time.

### Relative-to-exe lookup (for the companion-archive path)

Resolve the running executable, then look for the data beside it:

- **Linux** — `readlink("/proc/self/exe", …)`
- **macOS** — `_NSGetExecutablePath(…)`
- **Windows** — `GetModuleFileNameA(NULL, …)`

Lookup order, first hit wins: `$<EXE>/../share/<pkg>/<data>`, then
`$<EXE>/share/<pkg>/<data>`, then `$<EXE>/<data>`. If upstream already honors a
`$<EXE>/share/<thing>` lookup or a `<NAME>_RUNTIME` env var, just package the
data; don't patch. If it bakes absolute paths via autotools
(`--datadir=<prefix>/share`), patch the lookup function — copy upstream's own
Windows fallback ladder for `__linux__` / `__APPLE__`.

## Decision: which approach?

- **One blob behind a load-from-buffer API** → Pattern 1 (compiled-in). Smallest,
  simplest, no VFS.
- **A tree the program opens by path** → Pattern 2 (embedded ZIP + VFS). Single
  file, no first-run extract.
- **Neither fits** (very large data, or a lookup you can't intercept) →
  `package_data` companion archive + relative-to-exe lookup.
- Never wrap the binary in a shell script that sets env vars — that breaks the
  single-binary contract.

## Testing

Embedded data: copy **only** the binary to a fresh, empty directory and confirm
it still works with no `share/` beside it:

```bash
mkdir -p /tmp/<pkg>-test && cp result/bin/<pkg> /tmp/<pkg>-test/
cd /tmp/<pkg>-test && ./<pkg> --version    # must not need any companion file
```

For the companion-archive path, instead verify the relative lookup resolves
(binary plus `share/` in a fresh dir, never `/nix/store/...`). If a binary still
reports a `/nix/store/...` data path, its lookup wasn't patched —
`strings result/bin/<pkg> | grep -E 'share/<pkg>|/proc/self/exe|_NSGetExecutablePath'`.
