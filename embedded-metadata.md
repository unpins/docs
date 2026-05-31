# Embedded metadata (`unpin/*` in an embedded ZIP)

Every unpins executable can carry metadata *inside the binary* — multi-call
aliases and man pages today, more later — with no companion file. The container
is a **plain ZIP** holding entries under a reserved `unpin/` namespace; unpin
finds it by the ZIP's own structure and reads `unpin/*` out of it. This is the
single, format-agnostic mechanism for everything unpin embeds in a binary.

**Why a ZIP, not a hand-rolled container.** The producer is Python stdlib
(`zipfile`) plus Nix/objcopy; the consumers are unpin (Rust `zip` crate, already
linked) and — for packages that read their *own* runtime from an embedded ZIP —
the in-tool VFS (miniz, see [runtime-data.md](runtime-data.md)). A ZIP gives the
central directory (locator + index), per-entry CRC (integrity), and per-entry
compression for free, with real tooling (`unzip -l <binary>`) for debugging. No
invented framing.

**No marker, no sentinel.** Earlier drafts wrapped the payload in a `0xff`
sentinel. That is gone. The ZIP is located by its native end-of-central-
directory record; our data is identified by the `unpin/` entry-name namespace.
The security of aliases never depended on a marker (see §4) — it lives in the
catalog-owner gate and the blocklist, both upstream of this reader.

---

## 1. Where the ZIP lives

A standard ZIP whose bytes sit somewhere in the binary file. unpin does **not**
parse ELF/PE/Mach-O section tables — it scans the raw bytes — so one reader
works on every object format and survives `strip`. Concretely the producer puts
it in whichever place is natural and signing-safe for the target (§5):

- **ELF / PE (native, mingw)**: a trailing ZIP appended after the image, or an
  `llvm-objcopy --add-section` blob — either is found by the byte scan.
- **Mach-O**: appended past the code signature (`LC_CODE_SIGNATURE`), outside the
  signed range, so signing stays valid (same as the old alias embed).
- **cosmo APE**: the binary already has a tail-ZIP (cosmo bundles
  `usr/share/zoneinfo/*` etc.); we **add** `unpin/*` entries to *that* ZIP rather
  than appending a second one (a second trailing ZIP would shadow cosmo's
  end-of-central-directory and break its `/zip/` reader).

A binary may legitimately contain **other** ZIPs (a cosmo runtime ZIP, a tool's
own resource ZIP, a VFS runtime ZIP in a section). That is fine: those carry no
`unpin/` entries, so they contribute nothing. The `unpin/` namespace is what marks
data as ours, not the container's position.

---

## 2. Locating the ZIP (reader algorithm)

ZIP is anchored by its **End Of Central Directory** (EOCD) record. Standard
readers scan for it only near end-of-file; unpin scans the **whole** binary so
the ZIP can sit anywhere (trailing, in a section, or shared with a cosmo
tail-ZIP).

1. Scan the file bytes for the EOCD signature `50 4B 05 06` (`PK\x05\x06`).
2. For each hit at offset `e`, read the fixed EOCD fields:
   `cd_size` (`u32` at `e+12`), `cd_offset` (`u32` at `e+16`),
   `comment_len` (`u16` at `e+20`).
3. **Validate** it is a real EOCD, not a coincidental signature in code/data:
   - `cd_start = e − cd_size` and `zip_start = cd_start − cd_offset` must be
     non-negative;
   - the bytes at `cd_start` must be the central-directory signature
     `50 4B 01 02` (`PK\x01\x02`).
   A chance `PK\x05\x06` in machine code fails this and is skipped.
   `0xFFFFFFFF` in `cd_size`/`cd_offset` means ZIP64 → unsupported (never
   produced), skip.
4. The validated ZIP occupies `[zip_start, e + 22 + comment_len)`. Because
   `zip_start` is computed from the EOCD, this slice is a clean, zero-prefix ZIP
   — hand it to the `zip` crate (a `Cursor` over the slice) and read entries by
   name.
5. A binary can yield **several** validated ZIPs. Collect `unpin/*` entries from
   all of them (§3). Non-`unpin/` entries are ignored.

The reader reads the binary into memory to scan and slice; peak memory is the
binary size, transient (the binary was just downloaded or is already installed).

### 2.1 Self-scan is not special

unpin embeds its **own** `meta` ZIP (its `unpin.1`, via `build.rs` +
`include_bytes!`). When `unpin man` scans `unpin` itself, the reader's own
constants in `.rodata` are **not** valid EOCDs (no `PK\x05\x06` followed by a
consistent central directory), so the §2.3 validation rejects them with no
special-casing. This is cleaner than the old sentinel scan, which needed an
explicit "skip the reader's own marker constant" rule.

---

## 3. Entry layout (`unpin/` namespace)

All metadata lives under `unpin/`. Entries are plain ZIP members; compression is
per-entry (`stored` or `deflate` — `deflate` is the only compressed method used,
so miniz / `zipfile` / `flate2` all read it; no `zstd`).

### 3.1 Aliases — `unpin/aliases`

UTF-8 text, **one alias name per line** (`\n`). Blank lines and lines starting
with `#` are ignored. Absent entry or empty list = no aliases. Example:

```
xzcat
unxz
lzma
unlzma
```

The reader dedups, preserving first-seen order. Name **validation** (charset,
length ≤ 64, no leading dot/dash, Windows-reserved, the credential/runtime
blocklist) happens at install time in `unpin/src/aliases.rs::validate_alias` —
unchanged by this format.

### 3.2 Man pages — `unpin/man/<name>.<section>[`…`]`

roff source, one entry per page:

- English (default): `unpin/man/<name>.<section>` — e.g. `unpin/man/unpin.1`,
  `unpin/man/fdisk.8`.
- Other language: `unpin/man/<lang>/<name>.<section>` — e.g.
  `unpin/man/pt_BR/unpin.1`. (v1 ships `en` only; the subdir is the forward path.)
- `.so` redirect (`vigr.8` → `.so man8/vipw.8`): a **ZIP symlink entry** whose
  content is the target's `<name>.<section>` (the basename suffices; any leading
  `manN/` path is stripped on read). Stored as a symlink (unix mode `S_IFLNK`,
  creator-system = unix) so it dedupes the shared target and resolves *within*
  the archive — there is no filesystem to `.so` into. The reader follows
  redirects with cycle detection, capped at depth 4; a cycle or dangling target
  errors naming the broken redirect.

`<section>` is read as its leading digits (`1`, `8`, `3` from `3pm`). Lookup key
is `(name, section, lang)`: prefer the requested language then fall back to `en`;
with no section requested, take the lowest-numbered section present.

### 3.3 Future namespaces

New kinds are new `unpin/` sub-prefixes (`unpin/completions/…`, `unpin/provenance`,
…). An old reader ignores prefixes it doesn't know — the central directory makes
every entry independently addressable, so forward-compat is automatic.

---

## 4. Security model

Aliases create `PATH` symlinks, so a malicious alias (`sudo`, `ssh`, `git`)
could intercept credentials or escalate. The defenses are **upstream of this
reader** and do not rely on any container marker:

1. **Catalog-owner gate** (`unpin/src/install/linker.rs`): aliases are honored
   **only** when `spec.owner == unpins`. A `<owner>/<repo>` install ignores all
   declared aliases regardless of what it embeds — so a foreign binary can never
   inject aliases, no matter what ZIPs it carries.
2. **Blocklist + validation** (`validate_alias`): even a catalog package cannot
   declare a blocked name, a path-traversal name, a Windows device name, or an
   over-long/illegal name. This is the defense-in-depth layer if catalog CI is
   ever compromised.

A content marker / "exactly one block" rule would add nothing against either
threat (a foreign binary is gated out by owner; a compromised CI would forge any
marker), so it is omitted. The one cheap guard kept: if **two distinct ZIPs** in
one binary both carry `unpin/aliases`, the reader **errors** ("refusing to
guess") rather than picking one — this never fires for a binary we built (we
embed once) but turns an ambiguous tampered/bundled artifact into a loud failure
instead of a silent guess.

**Man has no security boundary.** `unpin man` reads `unpin/man/*` from any binary,
including foreign (`<owner>/<repo>`) packages — worst case is wrong documentation,
never a hijacked link. No owner gate, no dedup guard; first/union of `unpin/man/*`
across the binary's ZIPs wins.

Per-entry CRC-32 (native to ZIP) detects truncation/corruption; it is integrity,
not authenticity — the release pipeline publishes `.sha256` sidecars for that.

---

## 5. Producer side

### 5.1 unpin itself (`build.rs`)

unpin's `unpin.1` is hand-authored, so `build.rs` builds a tiny **stored** ZIP
with one entry `unpin/man/unpin.1` and `include_bytes!`-plants it (`#[used]`, so
it survives LTO + strip). No compression (the page is small), no Python — the
build stays dependency-free. The reader then finds it via §2 like any other
binary's ZIP.

### 5.2 Catalog packages (nix-lib)

A `withMeta` step (folding the old `withAliases` + `withMan`), run in
`postFixup` after strip, ensures the binary has a ZIP and puts `unpin/*` in it:

- Aliases: write `unpin/aliases` (one name per line) when the package declares
  them (explicit list or auto-collected multi-call applet symlinks, same
  collection + validation as today).
- Man: collect `$out/share/man/man[0-9]/*` (gunzip `.gz`); a body that is only a
  `.so <path>` becomes a symlink entry, otherwise a roff entry, `deflate`-
  compressed. Cross builds (Windows/cosmo) source man from the matching Linux
  build (man is OS-independent), version-locked to the same nixpkgs pin.
- Placement per §1: ELF/PE add-section or trailing; Mach-O trailing past the
  signature; cosmo add entries to the existing tail-ZIP. Produce with `zipfile`
  (stdlib): `deflate` + per-entry CRC are built in; for symlink entries set
  `create_system = 3` (unix) and `external_attr = (0o120777 << 16)`. **No EOCD
  comment / marker is written.**

Because aliases are catalog-only and we build these binaries, there is exactly
one `unpin/aliases` and the §4 guard never fires.

---

## 6. Reader implementation (`unpin/src/meta.rs`)

- `meta::read(path) -> Result<Option<Meta>, String>` — scans for ZIPs (§2),
  materializes `unpin/*` entries (with size caps), enforces the `unpin/aliases`
  dedup guard (§4). `Ok(None)` = no `unpin/*` anywhere.
- `Meta::aliases() -> Vec<String>` — parse `unpin/aliases` (dedup, skip blank/`#`).
- `Meta::entries_under(prefix)` / `entry(path)` — raw access. The stable
  `unpin bundle list|dump` subcommand (`unpin/src/bundle.rs`) is built on these
  and is what the `man` package consumes; see [embedded-man.md](embedded-man.md).
- Caps: max entries, per-entry size, total `unpin/*` bytes, and a max file size to
  scan — so a crafted ZIP can't drive unbounded allocation.

Dependencies: the `zip` crate (already linked, `deflate-flate2` feature) for
reading; no ELF/PE/Mach-O parser. Rendering man pages is **not** unpin's job —
the `man` package (patched mandoc) pulls the roff back out via
`unpin bundle dump` and renders it. See [embedded-man.md](embedded-man.md).

---

## 7. Limits & forward-compat

- ZIP is the version boundary: new metadata kinds are new `unpin/` sub-prefixes;
  unknown prefixes are ignored by older readers (no format-version byte needed).
- Caps (reader-enforced): see §6. `deflate` only (no `zstd`) so the in-tool VFS
  (miniz) and `zipfile`<3.14 both read the same bytes.
