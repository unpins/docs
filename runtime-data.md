# Packages with runtime data

Some programs need files beyond the executable at runtime: `vim` needs its
`share/vim/<ver>/` runtime tree (syntax, ftplugin, doc, …), `gvim` the same,
`file` needs its magic database (`magic.mgc`). unpins ships these
**inside the binary** — no companion file, no extract-on-first-run — so the
single-binary contract holds. A separate `.tar.zst` next to the binary
(`package_data`) still exists for the rare case embedding can't cover (today
only `nmap`), but it is **off by default**; embedding is the norm.

There are two embedding patterns, picked by how the program consumes the data.

## Pattern 1 — compiled-in blob (one file behind a load-from-buffer API)

When the data is a single blob the program loads through a library call, compile
it straight into the binary (`xxd -i` emits a C array) and feed the in-memory
buffer to that call. Best when upstream already has a "load from a buffer" entry
point and the data is one file.

No catalog package uses this today — `file`, the original worked example, moved
its `magic.mgc` to Pattern 2 (the ZIP compresses it, and the data stops forcing
a relink; see `file/flake.nix` + `file-vfs-magic.patch`). The pattern stays
valid and engine-safe (a C array compiles into the bitcode module like any other
data), unlike `.incbin` — see the ban below.

## Pattern 2 — runtime tree in the embedded ZIP + in-tool VFS (a tree opened by path)

When the program opens many files by path at runtime (a whole runtime tree),
ship the tree inside the binary's **single embedded ZIP** — the same
container that carries `unpin/aliases` and `unpin/man/*`
([embedded-metadata.md](embedded-metadata.md)) — and add a tiny virtual
filesystem that intercepts the program's own file calls for a marker path and
serves them from that ZIP. The VFS core is shared — `unpins-lib.lib.vfsCore`
points at the reader half of github:unpins/unpin-vfs, vendored once inside
`nix-lib` and copied into each consumer's build (`cp ${lib.vfsCore}/*.c … src/`;
nine packages use it: vim, gvim, file, perl, biber, tcc, zsh, xvfb, xvnc) —
and runs in **self-EOF mode**
(`-DUNPIN_VFS_SELF`): `unpin_vfs_init()` locates the running executable
(`/proc/self/exe`, `_NSGetExecutablePath`, `GetModuleFileNameW`), opens it
read-only and reads the ZIP straight off its EOF — the absolute, file-adjusted
offsets the embed writes mean the whole file parses as one archive. No
`.incbin`/`blob.S` section, no relink when only data changes; the `unpin/` and
`.unpin/` namespaces are hidden from VFS lookups and listings.

`vim` is the worked example (`vim/flake.nix`; VFS sources copied from
`lib.vfsCore` — `vfs.c`, `vfs.h`, `miniz.c`, `unpin_zstd.c` + `zstddeclib.c` —
plus per-package glue `unpins_init.c`). The build:

1. `injectVfs` copies in the VFS core + glue. `unpins_init()` is injected right
   after `mch_early_init()` in `main.c`; on Linux the libc file calls are
   rerouted at link time (`ld --wrap`), on macOS by `llvm-objcopy
   --redefine-sym` + relink, and on Windows `mch_open` / `mch_fopen` (real
   wide-char wrapper functions) get a virtual-path dispatch patched in at
   entry.
2. ONE `withUnpinEmbed` call (nix-lib) builds the whole embedded container in
   `postFixup` (after strip): `runtimeStage` stages the `share/vim/vim<NN>`
   tree CONTENTS as the ZIP root, `aliases = [ "xxd" ]` adds `unpin/aliases`,
   and `man = true` (native) / `manRoot` (windows) adds `unpin/man/*` — a
   single pack writes the binary's one ZIP, runtime entries as zstd method-93
   against the shared `.unpin/zdict` dictionary, smaller than the old deflate
   blob. (`withRuntimeData` still exists as a thin wrapper for a
   runtime-tree-only call.)
3. `postInstall` removes the on-disk `share/vim/vim*` — the tree now lives only
   in the binary.

The VFS sources come from `unpins-lib.lib.vfsCore` (never copy another
package's — they'd drift); miniz is built with `-DMINIZ_NO_*` so only the
inflate path is linked, plus `-DMINIZ_USE_ZSTD` with the vendored
decompress-only `zstddeclib.c`.

> The runtime tree and the `unpin/*` metadata (aliases + man pages, see
> [embedded-metadata.md](embedded-metadata.md)) share the binary's ONE
> embedded ZIP but never mix: `unpin/*` and `.unpin/*` are unpin's namespaces,
> read by the `unpin` CLI and hidden from the package's own VFS; everything
> else is the runtime tree, served by the VFS and ignored by unpin's reader.
> Every VFS package (vim, gvim, file, perl, biber, tcc, zsh, xvfb, xvnc) uses
> this self-EOF model; the old `.incbin` blob-section variant is gone.

**A runtime tree must use this pattern — `.incbin`/`blob.S` is banned, not
merely retired.** An `.incbin` names a file resolved when the *assembler* runs.
Under the engine the package compiles to a bitcode module, so that reference
survives unresolved into `module.bc`, and the multicall mega-link runs in a
different working directory, where the file does not exist: the darwin mega
fails to link. The self-EOF ZIP is appended *after* the link (`unpinEmbedWrap`
for a standalone binary, `withRuntimeData`/`withUnpinEmbed` inside the mega), so
it is mega-safe and byte-identical across linux, the crosses, darwin and
windows. Pattern 1 is unaffected — `xxd -i` emits a C array that compiles into
the module like any other data.

## Fallback — companion archive (`package_data`, opt-in)

`package_data` is `false` by default in `mkStandaloneFlake`. Set it `true` only
for a package that genuinely can't embed its data. action-build then attaches
`<pkg>-<version>-data.tar.zst` (built from `result/share/`, gated on it existing) to
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
