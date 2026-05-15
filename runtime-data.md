# Packages with runtime data

Some packages need files beyond the binary at runtime: `vim` needs its `share/vim/<ver>/` runtime tree, `gvim` the same, `file` needs `share/misc/magic.mgc`, etc. unpins handles this with a companion data archive plus a relative-to-exe lookup pattern.

## The data archive

`package_data` is already `true` by default in `mkStandaloneFlake`. Action-build conditions the tar step on `result/share/` actually existing — packages without it (jq, htop, ...) silently skip the data archive. Packages that produce a `share/` subtree get `<pkg>-<tag>-data.tar.zst` attached to the GitHub release automatically.

The `unpin` CLI detects the companion (`<pkg>-<tag>-data.tar.zst`) and extracts it into the version directory, so the on-disk layout after `unpin install <pkg>` looks like (Linux defaults):

```
~/.local/share/unpin/<owner>/<pkg>/<tag>/
├── bin/<pkg>
└── share/
    └── ...                       # contents of the data archive
```

`~/.local/bin/<pkg>` symlinks to `bin/<pkg>` inside that directory. On Windows the layout collapses into `%LOCALAPPDATA%\unpin\packages\<owner>\<pkg>\<tag>\` plus a `.cmd` wrapper next to `unpin.exe`.

## Relative-to-exe lookup

When the upstream build bakes `share/...` paths into the binary, those paths point into `/nix/store/HASH-<pkg>-VER/share/...` — a path that doesn't exist on the user's machine. The binary either errors at startup or silently falls back to a degraded mode.

Patch the binary to look up the data relative to the running executable:

### Linux

```c
#include <unistd.h>
#include <limits.h>

char exepath[PATH_MAX];
ssize_t n = readlink("/proc/self/exe", exepath, sizeof(exepath) - 1);
if (n > 0) {
    exepath[n] = '\0';
    /* exedir/../share/... */
}
```

### macOS

```c
#include <mach-o/dyld.h>

char exepath[PATH_MAX];
uint32_t sz = sizeof(exepath);
if (_NSGetExecutablePath(exepath, &sz) == 0) {
    /* exedir/../share/... */
}
```

### Windows

```c
#include <windows.h>

char exepath[MAX_PATH];
if (GetModuleFileNameA(NULL, exepath, MAX_PATH)) {
    /* exedir/../share/... */
}
```

Conventional lookup order — pick the first that exists:

1. `$<EXE>/../share/<pkg>/<data>` (when `argv[0]` resolves under a `bin/` dir)
2. `$<EXE>/share/<pkg>/<data>` (flat layout)
3. `$<EXE>/<data>` (single-dir co-location)

This mirrors the convention upstream Windows tools like `file` already follow via `_w32_get_magic_relative_to`.

## Worked examples in the workspace

- **`vim`** — Vim has native `$VIMRUNTIME` discovery; the binary already locates `share/vim/<ver>/` relative to itself. No patch needed; the default `package_data = true` is enough.
- **`gvim`** — Same as vim.
- **`file`** — Upstream `magic.c`'s `get_default_magic()` already searches relative to `argv[0]` on Windows (`_w32_get_magic_relative_to`). The `file/file-magic-relative.patch` extends the same logic to Linux (`/proc/self/exe`) and macOS (`_NSGetExecutablePath`), reading `<exedir>/../share/misc/magic.mgc`. See `file/flake.nix`.

## Decision: patch or rely on upstream?

- If upstream already supports a `$<EXE>/share/<thing>` lookup or honors a `<NAME>_RUNTIME` env var, just package the data; don't patch.
- If upstream bakes absolute paths via autotools (`--datadir=<prefix>/share`), patch the lookup function. Use the existing Windows code in upstream as a model — copy the same fallback ladder for `__linux__` / `__APPLE__`.
- Never wrap the binary in a shell script that sets env vars — that breaks the single-binary contract.

## Testing

After building, copy the binary to a fresh directory and verify the runtime lookup:

```bash
mkdir -p /tmp/<pkg>-test/bin /tmp/<pkg>-test/share/<pkg>
cp result/bin/<pkg> /tmp/<pkg>-test/bin/
cp -r result/share/<pkg>/* /tmp/<pkg>-test/share/<pkg>/

/tmp/<pkg>-test/bin/<pkg> --version          # should report the relative-lookup data path
```

If the binary still reports `/nix/store/...`, the patch didn't apply — verify with `strings result/bin/<pkg> | grep -E 'share/<pkg>|/proc/self/exe|_NSGetExecutablePath'`.
