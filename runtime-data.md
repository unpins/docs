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

## Pattern 2 — embedded ZIP + in-tool VFS (a tree opened by path)

When the program opens many files by path at runtime (a whole runtime tree), pack
the tree into a ZIP, link it into the binary as a section, and add a tiny virtual
filesystem that intercepts the program's own file calls for a marker path and
serves them from the in-memory ZIP.

`vim` / `gvim` are the worked example (`vim/flake.nix`; VFS sources
`vim/unpins_vfs.c`, `unpins_init.c`, `miniz.c`, `unpins_runtime_data.S`). The
build (`injectVfs`):

1. Packs `share/vim/vim<NN>` to a deflate ZIP (`zip -9`); the major-version dir
   name is read out of the tree, not tracked by hand.
2. Stages it at `src/unpins_runtime.zip` and links it into the binary as a
   section via `.incbin` (`unpins_runtime_data.S`).
3. Copies in a ~410-LOC C + miniz VFS layer. `unpins_init()` is injected right
   after `mch_early_init()` in `main.c`, and a hooks include goes **inside**
   `vim.h`'s `VIM__H` guard so vim's `mch_open` / `mch_fopen` route paths under
   the VFS marker to the in-memory ZIP. On Windows those are real functions
   (wide-char wrappers), so their bodies are patched to dispatch virtual paths at
   entry instead of via macro.
4. `postInstall` removes the on-disk `share/vim/vim*` — the tree now lives only
   in the binary.

The VFS sources live in the package repo (copy `vim/`'s as a starting point);
miniz is built with `-DMINIZ_NO_*` so only the inflate path is linked.

> Don't confuse this with the `unpin/*` metadata ZIP (aliases + man pages, see
> [embedded-metadata.md](embedded-metadata.md)). That is unpin's own namespace,
> located by a whole-file byte scan and read by the `unpin` CLI; a package's
> runtime VFS ZIP is a separate blob in its own section, read by the program
> itself, and carries no `unpin/` entries.

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
`%LOCALAPPDATA%\unpin\packages\<owner>\<pkg>\<tag>\` plus a `.cmd` wrapper. On
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
