# Embedded man pages (`unpin man`)

Every unpins executable carries its own man pages *inside the binary* as roff
source, so documentation needs no companion asset. `unpin man <pkg> [page]`
renders them. This killed the per-package man-only data tarball (jq, tmux, curl,
…) and gives Windows — which has no `man` — offline-quality docs.

There are two pieces, owned in different places:

1. **Storage** — the roff lives in the embedded-metadata ZIP under
   `unpin/man/<name>.<section>`. The container, the byte-scan locator, `.so`
   symlink redirects, and the build/embed side are specified in
   [embedded-metadata.md](embedded-metadata.md) — that is the authoritative
   spec. This document covers only the *man* side: how a page is fetched and
   rendered.
2. **Rendering** — done by the **`unpin-man` package** (`unpins/unpin-man`, a
   patched mandoc), **not** by unpin. unpin "knows nothing about man."

## Architecture: man is a package, not a builtin

`unpin man` was originally planned as a built-in, pure-Rust roff renderer (a
pandoc/mandoc port living in `unpin/src/man/`). That was **scrapped**
(2026-05-30). Re-implementing a roff engine in Rust is a large, perpetual
maintenance burden, and FFI-linking mandoc's C into `unpin` would break unpin's
zero-`unsafe`, near-zero-dependency invariant. Instead:

> **`unpin man` is a thin verb dispatch to the `unpins/unpin-man` package — a
> patched mandoc.** The mature, canonical C renderer lives *in the package*, not
> in `unpin`; unpin stays pure Rust.

Helper verbs in general (man today; changelog/readme conceivably later) are
packages, not builtins, named `unpins/unpin-<verb>` and reached only via
`unpin <verb>` — never placed on `PATH`. The dispatch precedence and the catalog
naming reservation that keep `man` from colliding with the OS or the catalog are
specified in [helper-verbs.md](helper-verbs.md); the only unpin-side surface is
the `bundle` interface below.

### Flow (man → unpin, not unpin → man)

```
unpin man coreutils ls
   │  default-run injection (parse_args) resolves the bare name `unpins/man` as a
   │  program; on a genuine 404 it falls back to the `unpins/unpin-man` helper
   │  package (helper-verbs.md) — fetched on demand, never linked onto PATH
   ▼
runs the unpin-man package (unpins/unpin-man, patched mandoc) with `coreutils ls`
   │  `run` exports $UNPIN_SELF = unpin's own path (install/mod.rs)
   ▼
man front-end (unpin_man.c) shells back to unpin:
   $UNPIN_SELF bundle list coreutils         → pick section/lang, find .so target
   $UNPIN_SELF bundle dump coreutils <entry> → roff bytes on stdout
   ▼
piped into mandoc_main as stdin → renders man(7)/mdoc(7) to the terminal
```

The hard part — scan for the ZIP's EOCD, validate it, slice it out of the binary
— stays in unpin's tested Rust (`meta.rs` + `bundle.rs`). The mandoc patch only
swaps "read `/usr/share/man`" for "shell out to `unpin bundle`."

## The `unpin bundle` interface — the contract

`unpin bundle <op>` is the **stable, versioned** interface helper packages depend
on (it is *not* a hidden command). It exposes a package's embedded `unpin/*`
entries. Two ops, both fully in-memory (no temp files):

- **`unpin bundle list <pkg>`** — one line per entry: `path<TAB>size`, or
  `path<TAB>-> target` for a `.so` symlink entry. The line format is a stable
  contract, pinned by a test (`entry_line`).
- **`unpin bundle dump <pkg> <entry>`** — streams that one entry's exact bytes to
  stdout; prints nothing (and exits 0) if the entry — or the whole bundle — is
  absent.

`<pkg>` is resolved via `install::installed_binaries` (`unpin` itself resolves to
`current_exe`); the first installed binary carrying a bundle is read.

**Family rule: absence is not an error.** A missing entry, or a binary with no
bundle at all, exits 0 with empty output. Only a *real* failure exits non-zero:
package not installed, binary unreadable, bundle corrupt. `bundle` is **not** a
security boundary — the alias trust gate lives in `install/linker.rs`, gated on
`owner == unpins` (see [embedded-metadata.md](embedded-metadata.md) §4). `man`
reads any binary's `unpin/man/*`, foreign packages included; worst case is wrong
documentation, never a hijacked link.

`extract` and `info` ops were considered and **cut** (YAGNI). The man package
needs only `list` (to pick section/language and discover `.so` targets) + `dump`
(to stream roff into `mandoc -man` via stdin). It never writes a file, so there
is no untrusted-name materialization and no path-traversal sanitization to do.

### `.so` redirects

A whole-page `.so` (`vigr.8` → `.so man8/vipw.8`) is a ZIP **symlink** entry;
`bundle list` reports it as `-> target` and the `man` package resolves it itself
(list → dump the target), with cycle detection capped at depth 4. An **inline**
`.so` *inside* a roff body is not resolved — there is no on-disk man tree for
mandoc to source from, so it only warns. Irrelevant in practice: catalog man is
generated (help2man / asciidoctor) and only ever emits whole-page redirects.

## The `unpin-man` package (`unpins/unpin-man`)

A patched mandoc 1.14.6 built through `mkStandaloneFlake`, released like any
other catalog package (tag `v1.14.6-<pkgrel>`, `own_software = false`). It is a
helper verb, so it ships under the `unpin-` prefix and is never linked onto PATH
(see [helper-verbs.md](helper-verbs.md)). Three source pieces:

- **`unpin-front-end.patch`** — renames mandoc's `main` → `mandoc_main`, and
  relinks the Makefile `man:` target around `unpin_man.o` + `$(MAIN_OBJS)` +
  `libmandoc.a` (instead of symlinking `mandoc` → `man`).
- **`unpin_man.c`** — the new `main`: parses `man <pkg> [page]` (page defaults to
  `<pkg>`), runs `bundle list`, ports the section/language pick + `.so` follow
  (depth ≤ 4), then `fork`/`exec`s `bundle dump` with stdout→pipe→stdin and calls
  `mandoc_main` with `argv[0] = "mandoc"` (which forces "read stdin as a file"
  across all three toolchains). mandoc auto-detects man vs mdoc.
- **`flake.nix` / `cosmo.nix`** — the build. `buildFlags = ["man"]` (only the
  `man` target — the `mandoc` target would fail to link without `main`),
  `doCheck = false` (the regress suite rebuilds `mandoc`). mandoc's build target
  is `man`; the install renames it to `bin/unpin-man` so the binary, the asset,
  and the package name agree (action-build locates the primary at `bin/<name>`).

### Platform notes (mandoc's configure runs probes)

mandoc's `./configure` *executes* probe binaries, so a cross build whose build
box can't run the host's binaries can't probe. `meta.broken` is forced false, and:

- **Targets the build box can't execute** (ppc64le / riscv64 / armv7l): preset
  `HAVE_*` in `configure.local`, harvested from a native musl probe, plus
  `NEED_GNU_SOURCE=1` (musl hides `strcasestr`/`strndup` behind `_GNU_SOURCE`).
  `HAVE_NANOSLEEP=1` + `O_DIRECTORY`/`PATH_MAX`/`ATTRIBUTE` must be pinned
  explicitly: mandoc only writes `#define HAVE_X` for *absent* features (to emit
  a compat shim), so a *present* feature leaves no trace to harvest and the cross
  probe would default it to 0 → `FATAL`.
- **Targets it can execute** (i686; x86_64-darwin under Rosetta on the aarch64
  runner): real probes run, no preset. `needsPreset` is gated on
  `hostPlatform.isLinux` so a darwin host never gets the Linux harvest (which
  would pull in `<endian.h>`, absent on macOS).
- **Windows via Cosmopolitan** (`cosmo.nix`): cosmo libc has `fork`/`exec`/`pipe`
  (mingw's CRT does not), which the front-end needs. The APE executes on the
  Linux build box, so configure runs real probes — no preset. zlib is kept
  (uniform config); the only fix is adding `cosmoPkgs.zlib.static` to
  `buildInputs`, because cosmo's zlib is split-output and `buildInputs` otherwise
  resolves to `dev` (no `libz.a`; the archive lives in the `static` output). The
  unpins pipeline strips the APE down to a Windows-only PE32+, so smoke-test it
  on the Windows VM, not on Linux. See [platforms/cosmocc.md](platforms/cosmocc.md).

## What unpin still embeds

The roff is still embedded into every package by `withMan` / `embedMan`
(default-on) at build time, exactly as [embedded-metadata.md](embedded-metadata.md)
§5 describes. `unpin`'s own hand-authored `unpin.1` goes through the same
pipeline: its flake passes the page as a `withMan` `manRoot`, so the nix build
appends the standard `unpin/man/unpin.1` overlay and `unpin man unpin` works —
the `unpin-man` package reads it back out of the `unpin` binary through
`unpin bundle`. (A plain `cargo install` build has no overlay, hence no
embedded manual.)

See [runtime-data.md](runtime-data.md) for the broader picture of packages
embedding what they used to ship as companion files.
