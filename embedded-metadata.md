# Embedded metadata (`unpin/*` in an embedded ZIP)

Every unpins executable can carry metadata *inside the binary* — multi-call
aliases and man pages today, more later — with no companion file. The container
is a **plain ZIP** holding entries under a reserved `unpin/` namespace; unpin
finds it by the ZIP's own structure and reads `unpin/*` out of it. This is the
single, format-agnostic mechanism for everything unpin embeds in a binary.

**Why a ZIP, not a hand-rolled container.** The producers are the `zip` CLI /
Python `zipfile` (aliases, `deflate`) and the C `unpin-vfs-pack` (man, `zstd` —
§3.4), plus Nix/objcopy; the consumers are unpin (a hand-rolled central-directory
walk in `meta.rs`, decompressing with `flate2`/`ruzstd`, both already linked) and
— for packages that read their *own* runtime from an embedded ZIP — the in-tool
VFS (miniz, see [runtime-data.md](runtime-data.md)). A ZIP gives the central
directory (locator + index), per-entry CRC (integrity), and per-entry compression
for free, with real tooling (`unzip -l <binary>`) for listing. No invented
framing.

**No marker, no sentinel.** Earlier drafts wrapped the payload in a `0xff`
sentinel. That is gone. The ZIP is located by its native end-of-central-
directory record; our data is identified by the `unpin/` entry-name namespace.
The security of aliases never depended on a marker (see §4) — it lives in the
catalog-owner gate and a per-name confirmation for credential commands, both
upstream of this reader.

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
own resource ZIP, a not-yet-migrated VFS runtime blob in a section). That is
fine: those carry no `unpin/` entries, so they contribute nothing. The `unpin/`
namespace is what marks data as ours, not the container's position. The reverse
also holds inside the ONE shared ZIP: a package's VFS runtime tree
([runtime-data.md](runtime-data.md) pattern 2) lives at the ZIP root next to
`unpin/*`, unpin's reader ignores it, and the VFS hides `unpin/*` from the
program.

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
   `zip_start` is computed from the EOCD, this slice is a clean, zero-prefix ZIP.
   The reader walks the central directory itself — each `PK\x01\x02` record, then
   the `PK\x03\x04` local header it points at, to slice out that entry's raw
   payload — rather than going through the `zip` crate. Parsing by hand is what
   lets it decode ZIP method 93 (Zstandard, §3) with the pure-Rust `ruzstd` it
   already links, so every cross target (mingw, i686/riscv64-musl) keeps building.
5. A binary can yield **several** validated ZIPs. Collect `unpin/*` entries from
   all of them (§3). Non-`unpin/` entries are ignored.

The reader reads the binary into memory to scan and slice; peak memory is the
binary size, transient (the binary was just downloaded or is already installed).

### 2.1 Self-scan is not special

unpin carries its **own** metadata overlay (its `unpin.1`), embedded by its nix
build through the same `withMan` pipeline as every catalog package (§5.1). When
`unpin man` scans `unpin` itself, the reader's own constants in `.rodata` are
**not** valid EOCDs (no `PK\x05\x06` followed by a consistent central
directory), so the §2.3 validation rejects them with no special-casing. This is
cleaner than the old sentinel scan, which needed an explicit "skip the reader's
own marker constant" rule.

---

## 3. Entry layout (`unpin/` namespace)

All metadata lives under `unpin/`. Entries are plain ZIP members; compression is
per-entry, one of three methods: `stored` (0), `deflate` (8), or `zstd`
(Zstandard, ZIP method 93). Aliases are tiny and stay `deflate`; man pages are
large and roff-redundant, so `withMan` packs them `zstd` — optionally against a
shared dictionary (§3.4), the bigger size lever. The reader decompresses all
three (`flate2` for deflate, `ruzstd` for zstd) and the in-tool VFS reads the
same bytes via miniz built `-DMINIZ_USE_ZSTD`. The compression method is the one
part of this format that is **not** silently forward-compatible — see §7.

### 3.1 Aliases — `unpin/aliases`

UTF-8 text, **one alias name per line** (`\n`). Blank lines and lines starting
with `#` are ignored. Absent entry or empty list = no aliases. Example:

```
xzcat
unxz
lzma
unlzma
```

The reader dedups, preserving first-seen order. Structural **validation**
(printable-ASCII only — so punctuation applets like coreutils' `[` link — minus
path separators and the Windows-invalid set, length ≤ 64, no leading dot/dash,
Windows-reserved) happens at install time in
`unpin/src/aliases.rs::validate_alias`, unchanged by this format. Credential
names (`sudo`, `ssh`, …) are *not* rejected there; they pass validation and are
gated by a per-name confirmation at link time (see §4).

### 3.2 Man pages — `unpin/man/<name>.<section>[`…`]`

roff source, one entry per page (`zstd`-compressed — see §3.4):

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
  errors naming the broken redirect. **In a `zstd` man overlay this symlink form
  is not used:** the zstd packer (miniz) stores no unix link mode, so `withMan`
  resolves each `.so` redirect to its target's bytes at stage time — the page
  ships as a full (well-compressing, dictionary-shared) copy, and the
  symlink-following path above applies only to legacy `deflate` overlays.

`<section>` is read as its leading digits (`1`, `8`, `3` from `3pm`). Lookup key
is `(name, section, lang)`: prefer the requested language then fall back to `en`;
with no section requested, take the lowest-numbered section present.

### 3.3 Future namespaces

New kinds are new `unpin/` sub-prefixes (`unpin/completions/…`, `unpin/provenance`,
…). An old reader ignores prefixes it doesn't know — the central directory makes
every entry independently addressable, so forward-compat is automatic.

### 3.4 Shared dictionary — `.unpin/zdict`

A man overlay big enough to benefit (raw page bytes ≥ 1 MiB) is packed against a
**shared Zstandard dictionary** trained over the page set (`zstd --train`), which
exploits cross-page roff redundancy for a much larger win than per-entry zstd
alone (perl: `deflate` 3.77 MiB → plain `zstd` ~3.4 MiB → `zstd`+dict 2.76 MiB).

The dictionary ships as one reserved entry, **`.unpin/zdict`**, `stored`. The
leading dot puts it *outside* the served `unpin/` namespace, so it is never
returned as a payload entry — it exists only so the reader can decode the
method-93 entries trained against it. The reader loads it once per overlay and
reuses a single `ruzstd` decoder across that overlay's entries; overlays with and
without a `.unpin/zdict` coexist in one binary, each decoded against its own dict
or none.

It is **size-gated and kept only if it pays.** The dict is ~110 KB `stored` —
dead weight on a small man set — so `withMan` trains it only above the 1 MiB
threshold and keeps the dict-packed overlay **only when it came out smaller** than
the plain-`zstd` one. The dictionary can therefore never enlarge a package, and a
too-small sample set simply falls back to plain `zstd`. A binary with a small man
set (e.g. bzip2) carries `zstd` entries and **no** `.unpin/zdict`.

---

## 4. Security model

Aliases create `PATH` symlinks, so a malicious alias (`sudo`, `ssh`, `git`)
could intercept credentials or escalate. The defenses are **upstream of this
reader** and do not rely on any container marker:

1. **Catalog-owner gate** (`unpin/src/install/linker.rs`): aliases are honored
   **only** when `spec.owner == unpins`. A `<owner>/<repo>` install ignores all
   declared aliases regardless of what it embeds — so a foreign binary can never
   inject aliases, no matter what ZIPs it carries.
2. **Structural validation** (`validate_alias`): even a catalog package cannot
   declare a path-traversal name, a separator/Windows-invalid name, a Windows
   device name, or an over-long/illegal name. At link creation a second,
   kernel-level layer backs this up — `platform::create_alias_link` routes the
   Unix symlink through cap-std (`openat2(RESOLVE_BENEATH)`), confining the link
   name to the bin dir even if a bad name slipped past validation.
3. **Credential confirmation** (`alias_needs_confirmation`): a tiny set of names
   whose silent shadowing harvests secrets or escalates privilege — `sudo`, `su`,
   `doas`, `ssh`, `gpg`, `gpg2` — is *not* refused (a catalog package may
   legitimately own one) but requires an explicit per-name prompt before linking,
   even under the default `aliases = yes`. `--yes` auto-confirms; a non-tty
   prompt defaults to skip. This is the defense-in-depth layer if catalog CI is
   ever compromised; ordinary footguns (`git`, `cargo`, a shell) are left to the
   owner gate rather than bloating the list.

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

### 5.1 unpin itself

unpin's `unpin.1` is hand-authored, but it ships through the **same** `withMan`
overlay as every catalog package: unpin's flake wraps the roff in a one-page
`share/man` tree and passes it as `manRoot`, so the nix build appends the
standard `unpin/man/unpin.1` overlay after strip. There is no `build.rs` /
`include_bytes!` special path anymore — one producer, one format. The trade-off:
a plain `cargo install unpin` build carries no overlay, so `unpin man unpin`
reports no embedded manual there (accepted: out-of-ecosystem builds).

### 5.2 Catalog packages (nix-lib)

`withUnpinEmbed pkgs { primary, aliases?/aliasesFromSymlinksIn?, man?,
manRoot?, manFallback?, runtimeStage? }` is the ONE call that builds a
package's embedded container: it stages every payload — the alias list, the
mkmeta.py man tree, and an optional VFS runtime tree
([runtime-data.md](runtime-data.md)) — into a single ZIP-root staging dir in
`postFixup` (after strip) and packs the binary's one EOF ZIP once. When the
call includes man, `mkStandaloneFlake` sees `passthru.unpinEmbedsMan` and
skips its own man application, so that call really is the only embed step.

`withAliases`, `withMan` and `withRuntimeData` remain as thin wrappers over it
(most catalog packages only ever need the implicit `withMan` that
`mkStandaloneFlake` applies). Composing several calls still works order-free —
each repacks the accumulated superset of the one ZIP, creating it if absent —
it just costs one repack per call. The payloads:

- Aliases: write `unpin/aliases` (one name per line) when the package declares
  them (explicit list or auto-collected multi-call applet symlinks, same
  collection + validation as today).
- Man: collect `$out/share/man/man[0-9]/*` (gunzip `.gz`); `mkmeta.py` stages a
  `.so <path>` body as a symlink and every other page as a roff file, then the
  overlay is packed `zstd` by `unpin-vfs-pack` (§3.4) — with the `.so` symlinks
  resolved to their target's bytes first, since that packer stores no unix link
  mode. **Every** target — native, cross-linux, AND Windows/cosmo —
  harvests man from its OWN `$out/share/man`: most cross builds install their
  man like any other (pre-generated roff in the tarball, or generators that run
  on the build host with no target execution), so they get the same pages
  native does, version-locked to the actual build. The cross build's own man is
  preferred; a consumer-set `winManRoot` (an explicit curated tree) overrides
  it, and the version-locked nixpkgs graft (`manFallback`) is consulted only
  when the cross build ships no man of its own — e.g. zstd, whose cmake gates
  the man install on UNIX (false for mingw). See `withMan` in `nix-lib`.
- Placement per §1: ELF/PE add-section or trailing; Mach-O trailing past the
  signature; cosmo adds entries to the existing tail-ZIP. The aliases overlay (and
  the cosmo tail-ZIP) are written with the `zip` CLI / `zipfile`: `deflate` +
  per-entry CRC are built in; for symlink entries set `create_system = 3` (unix)
  and `external_attr = (0o120777 << 16)`. The man overlay is a separate trailing
  ZIP written by `unpin-vfs-pack` (`zstd` + optional `.unpin/zdict`, §3.4) — except
  on cosmo, whose man pages fold into the tail-ZIP as `deflate` instead (its loader
  reads that ZIP and a `zstd` overlay can't merge into it). **No EOCD comment /
  marker is written by either.**

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

Dependencies: nothing beyond what unpin already links — a hand-rolled
central-directory parse plus `flate2` (deflate + CRC-32) and `ruzstd` (zstd,
method 93, pure-Rust). The metadata reader does **not** go through the `zip` crate
(that crate stays linked for release-asset archives, but reading method 93 through
it would pull in a C zstd and break the musl/mingw crosses). No ELF/PE/Mach-O
parser. Rendering man pages is **not** unpin's job — the `man` package (patched
mandoc) pulls the roff back out via `unpin bundle dump` and renders it. See
[embedded-man.md](embedded-man.md).

---

## 7. Limits & forward-compat

- ZIP is the version boundary: new metadata *kinds* are new `unpin/` sub-prefixes,
  ignored by older readers (no format-version byte needed). The **compression
  method** is the exception — it is not auto-forward-compatible. Adding `zstd`
  (method 93) for man pages required teaching the reader (`ruzstd`) and the
  in-tool VFS (miniz `-DMINIZ_USE_ZSTD`) about it *first*; an unpin built before
  that support cannot read a method-93 overlay (`unpin man <pkg>` would fail).
  Rollout is therefore ordered: ship the decoding reader, let it propagate, then
  flip `withMan` to emit `zstd`. (For ad-hoc debugging, `unzip -l` still lists
  method-93 entries but can't extract them; use a zstd-aware tool.)
- Caps (reader-enforced): see §6 — max entries, per-entry size, total `unpin/*`
  bytes, and a max file size to scan, so a crafted ZIP can't drive unbounded
  allocation.
