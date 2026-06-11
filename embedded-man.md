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
2. **Rendering** — done **in-process** by the `mandoc-sys` crate (a vendored,
   render-only subset of mandoc) that `unpin` links, paged by the shared
   reflowing pager in `unpin/src/render/`. unpin carries no roff logic of its
   own; the engine lives in the crate.

## Architecture: man is a builtin (render-only mandoc, linked)

`unpin man` has changed shape twice. It was first planned as a built-in,
pure-Rust roff renderer (a pandoc/mandoc port in `unpin/src/man/`) — **scrapped**
(2026-05-30), because reimplementing a roff engine in Rust is a perpetual
maintenance burden. It then shipped as a **separate package**
(`unpins/unpin-man`, a patched mandoc reached by verb dispatch) so the C renderer
lived outside unpin. That worked, but a man pager has to **reflow on resize** —
re-render the page at the new width — which means the renderer must run
*in-process* alongside the pager, not behind a subprocess. So as of 2026-06-11 it
is a **builtin** again:

> **`unpin man` renders in-process via the `mandoc-sys` crate** — a vendored,
> *render-only* subset of mandoc (roff bytes + width → ANSI), with no `main`, no
> fork/exec, no `./configure`. unpin links it; there is no man package.

`man` and `readme` are the two **builtin doc verbs**, each a small `Reflow`
renderer (man over `mandoc-sys`, readme over termimad) driven by one shared pager
in `unpin/src/render/`. The generic verb-**package** model (a verb shipped as
`unpins/unpin-<verb>`, reached by dispatch, never on `PATH`) still exists for a
future heavy/independent verb — see [helper-verbs.md](helper-verbs.md) — but man
and readme no longer use it.

### Flow (all in-process)

```
unpin man coreutils ls
   │  `man` is a builtin subcommand (src/main.rs); no fetch, no subprocess
   ▼
read coreutils' bundle in-process (meta.rs + bundle.rs):
   enumerate unpin/man/*  → pick section/lang, follow .so redirects (depth ≤ 4)
   read the chosen entry  → roff bytes
   ▼
mandoc_sys::render(roff, width) → ANSI, paged by src/render/ (reflows on resize)
```

The hard part — scan for the ZIP's EOCD, validate it, slice it out of the binary,
decode the entry — is unpin's tested Rust (`meta.rs` + `bundle.rs`), now called
directly instead of over `unpin bundle`.

## The `unpin bundle` interface — the contract

`unpin bundle <op>` is the **stable, versioned** interface a helper-verb
*package* depends on (it is *not* a hidden command) to read a binary's embedded
`unpin/*` entries without linking unpin. The builtin `man`/`readme` read those
entries in-process instead, so this interface now serves future, independent
verb-packages rather than them. Two ops, both fully in-memory (no temp files):

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
package not installed, binary unreadable, bundle corrupt. Of those, **package not
installed has its own exit code — `4` (`bundle::EXIT_NOT_INSTALLED`)** — distinct
from the generic `1`, so a consumer can tell it apart from a broken read without
parsing stderr text; this is part of the stable contract, for an independent
verb-package to offer a `run unpin install …` hint. (The builtin `man`/`readme`
read the bundle in-process and own this distinction directly, so they don't
depend on this exit code.) `bundle` is **not** a
security boundary — the alias trust gate lives in `install/linker.rs`, gated on
`owner == unpins` (see [embedded-metadata.md](embedded-metadata.md) §4). The
builtin `man` reads any binary's `unpin/man/*`, foreign packages included; worst
case is wrong documentation, never a hijacked link.

`extract` and `info` ops were considered and **cut** (YAGNI). A verb-package
needs only `list` (to pick section/language and discover `.so` targets) + `dump`
(to stream one entry's bytes). Neither op writes a file, so there is no
untrusted-name materialization and no path-traversal sanitization to do.

### `.so` redirects

A whole-page `.so` (`vigr.8` → `.so man8/vipw.8`) is a ZIP **symlink** entry
(`bundle list` reports it as `-> target`); the builtin `man` follows it in-process
(`render/man.rs`), with cycle detection capped at depth 4. An **inline**
`.so` *inside* a roff body is not resolved — there is no on-disk man tree for
mandoc to source from, so it only warns. Irrelevant in practice: catalog man is
generated (help2man / asciidoctor) and only ever emits whole-page redirects.

## The `mandoc-sys` crate (`unpins/mandoc-sys`)

The renderer is the `mandoc-sys` crate: a vendored, render-only subset of mandoc
compiled by a `build.rs` and linked into `unpin`. One safe function —
`render(roff, width) → String` (ANSI) — over a one-function C bridge
(`bridge.c`) that replaces mandoc's `main`: input goes through `mparse_readmem`
(no fd) and output is captured in memory on the `termp` buffer (no `FILE`, no
temp files). It re-parses on every call; pages are small, and the pager only
re-renders on resize, so a re-parse per render keeps the FFI to one function.

Because it is **render-only** — no front-end, no fork/exec — it builds the same
way `unpin` itself does, on every target:

- **No `./configure`.** mandoc normally *executes* probe programs to fill
  `config.h`, impossible when cross-compiling. `build.rs` synthesises `config.h`
  per target libc family (gnu / musl / darwin / mingw) instead, toggling which
  `compat_*.c` shims compile in.
- **No cosmo.** A native Windows `.exe` via **mingw** works, since there is no
  fork/exec front-end to need cosmo's libc. (The old package needed cosmo only
  for that front-end.)
- **~270 KB.** The compiled render subset adds about that much to the `unpin`
  binary on every platform — the accepted cost of in-process reflow.

The pager (`unpin/src/render/`) is shared with `readme` and is content-agnostic:
it pages ANSI lines and, on resize, asks the renderer (a `Reflow` impl) for a
fresh render at the new width.

## What unpin still embeds

The roff is still embedded into every package by `withMan` / `embedMan`
(default-on) at build time, exactly as [embedded-metadata.md](embedded-metadata.md)
§5 describes. `unpin`'s own hand-authored `unpin.1` goes through the same
pipeline: its flake passes the page as a `withMan` `manRoot`, so the nix build
appends the standard `unpin/man/unpin.1` overlay and `unpin man unpin` works —
the builtin `man` reads it back out of the running `unpin` binary in-process. (A
plain `cargo install` build has no overlay, hence no embedded manual.)

See [runtime-data.md](runtime-data.md) for the broader picture of packages
embedding what they used to ship as companion files.
