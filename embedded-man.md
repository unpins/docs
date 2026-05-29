# Embedded man pages (`.unpin_man` + `unpin man`)

Every unpins executable carries its own man pages *inside the binary*, so
`unpin man <pkg> [page]` renders documentation with no companion asset and no
network. This kills the per-package data tarball for the man-only cases (jq,
tmux, curl) and folds the man portion of the rest into the binary. It also gives
Windows — which has no `man` — offline docs.

**Status:**

- **On-disk format** (§1–§3) — final, frozen. roff-only, two entry kinds.
- **Build side** (`withMan` / `embedMan`, §4) — implemented in `nix-lib` and
  **default-on** across the catalog. Man-bearing packages embed automatically;
  man-less ones skip gracefully.
- **Renderer** (`unpin man`, §6) — designed, **not yet implemented**. Until it
  ships the embedded blob is unreadable; this is acceptable while there are no
  users, and binaries embedded now stay forward-compatible as the renderer grows.

Pages are stored as **roff source only**. A complete pure-Rust renderer
(man(7) + mdoc + tbl, §6) formats them at display time and reflows to the
terminal width. There is no build-time pre-rendering and no fixed-width fallback.

The format has **two nested layers**:

1. an **outer container** embedded in the binary, framing a single opaque blob;
2. an **inner archive** (the blob, compressed) holding N roff pages + an index.

This mirrors the existing `UNPIN_META` alias block (`nix-lib/flake.nix`,
`unpin/src/aliases.rs`): a named `llvm-objcopy` section whose *contents* are
located by a byte-scanned sentinel, so a single format-agnostic reader works on
ELF / PE / Mach-O / cosmo-APE.

Conventions: all integers **little-endian**; all strings **UTF-8**, length-
prefixed (no NUL terminator); offsets/lengths are `u32` unless stated.

---

## 1. Outer container

### 1.1 Where it lives

A dedicated section **`.unpin_man`**, written with
`llvm-objcopy --add-section .unpin_man=<file>` in `postFixup` (after stdenv
strip), exactly like `.unpin_meta`:

- `SHT_PROGBITS`, no `SHF_ALLOC`, `noload` → file-only, zero runtime memory.
- Survives `strip` (only debug/symbol sections are removed by name).
- Sits inside the code-signature envelope (does not invalidate signing).
- **Not** under the `.note.*` namespace (llvm-objcopy would parse it as ELF
  note records and reject raw bytes).
- **cosmo / APE**: reuse the existing tail-ZIP auto-detect path from the
  `withAliases` embed (PE-at-head + ZIP-at-tail); do not let a naïve
  `llvm-objcopy` drop the tail ZIP.

Distinct section name **and** distinct sentinel from `.unpin_meta`, so a binary
can carry both blocks (aliases *and* man) without ambiguity.

### 1.2 Framing

The reader cannot scan for an END marker — the payload is binary (zstd) and the
marker bytes can occur inside it by chance. So the BEGIN sentinel is followed by
a **length prefix**; END is written at the computed end only as a tripwire.

`S` = sentinel length (23, frozen — see §1.3); `L` = `payload_len`.

```
offset  size            field
------  --------------  -----------------------------------------------------
0       S (=23)         BEGIN_SENTINEL  (see 1.3, fixed bytes)
S       1               container_version   u8   = 0x01
S+1     1               compression         u8   0=none 1=zstd  (2=deflate reserved)
S+2     4               payload_len         u32  (compressed byte count)
S+6     L               payload             []   (compressed inner archive, §2)
S+6+L   4               payload_crc32       u32  CRC-32 (IEEE) of payload bytes
S+10+L  S (=23)         END_SENTINEL    (see 1.3, fixed bytes) — validation only
```

`L = payload_len`. Reader algorithm:

1. byte-scan the whole file for `BEGIN_SENTINEL` (reuse `find_in_chunks`).
2. read fixed header (`container_version`, `compression`, `payload_len`).
3. read exactly `payload_len` payload bytes, then `payload_crc32`, then assert
   the next 24 bytes equal `END_SENTINEL` (corruption / wrong-offset guard).
4. verify CRC; decompress per `compression` → inner archive (§2).

`container_version` unknown → refuse with "upgrade unpin". `compression`
unknown → same. Finding two BEGIN sentinels → refuse (as aliases.rs does).

### 1.3 Sentinels (exact bytes)

**Frozen at 23 bytes each** (interior tag 19 chars), bracketed by `0xff 0xff`
(illegal in UTF-8 and absent from roff text, same rationale as `UNPIN_META`).
The interior tag is ASCII; the `b2c9d1` suffix is a fixed nonce distinct from
the alias block's `7f3a4e`. BEGIN and END are the same width so the §1.2 step-3
END check is a fixed-size compare:

```
BEGIN: ff ff "UNPIN_MAN_v1_b2c9d1"   ff ff      (2 + 19 + 2 = 23)
END:   ff ff "UNPIN_MAN_ENDb2c9d1"   ff ff      (2 + 19 + 2 = 23)
```

These are the exact bytes emitted by `mkman.py` and scanned by the reader.

---

## 2. Inner archive (the compressed payload)

After decompression. Everything below is **one** byte stream so the solid
zstd compresses index strings and page bodies together (man roff is highly
repetitive across pages → big win for multicall packages).

```
offset  size          field
------  ------------  -------------------------------------------------------
0       6             magic            "UPMAN\x01"   (5 ASCII + version u8)
6       1             reserved         u8   = 0
7       2             entry_count      u16
9       4             index_len        u32   total bytes of the index region
13      index_len     index[]          (entry_count records, §2.1)
13+I    …             blob_region      concatenated roff page bodies (§2.2)
```

`I = index_len`. `blob_region` runs to end of stream.

### 2.1 Index record

Variable length. Repeated `entry_count` times:

```
size            field
--------------  ---------------------------------------------------------------
2               name_len        u16
name_len        name            UTF-8   (e.g. "ls", "fdisk", "tar")
1               section         u8      (1,3,5,8,… = the manN number)
2               lang_len        u16
lang_len        lang            UTF-8   ("en", "pt_BR", "zh_CN")
1               kind            u8      0=so_redirect  1=roff

  -- if kind == 0 (so_redirect):
2               tgt_name_len    u16
tgt_name_len    tgt_name        UTF-8
1               tgt_section     u8

  -- if kind == 1 (roff):
4               blob_off        u32     offset into blob_region
4               blob_len        u32     byte length of the roff source
```

The lookup key is the triple **(name, section, lang)**. Entries are stored
sorted by `(name, section, lang)` so the reader can binary-search; not required
for correctness (small N), but cheap and enables completion.

### 2.2 Body region

- **kind 1 (roff)**: raw roff source — man(7) or mdoc(7) macros, possibly with
  a `.TS`/`.TE` tbl block. Stored verbatim from `share/man` (gunzipped). The
  renderer parses and reflows it to `$COLUMNS` at display time. This is every
  real page.
- **kind 0 (so_redirect)**: no body. The `.so man8/vipw.8` stubs (§3.3).

There is no other kind. A complete renderer means roff is the only stored
representation.

---

## 3. Semantics

### 3.1 Which binary is read

`unpin man <pkg> [page]` reads the bytes of the **installed `<pkg>` binary**
(unpin knows the install path). A multicall binary (coreutils, util-linux,
shadow, …) carries every applet's page in one archive; a single-tool binary
(jq) carries one. No cross-package lookup in v1 (`unpin man mount` resolving to
util-linux is a later nicety).

### 3.2 Page + section + language selection

1. **page name**: explicit `[page]` arg, else the package's canonical name.
2. **section**: if the user passed `unpin man <pkg> <sec> <page>` honour it;
   else pick the lowest-numbered section present for that name (1 before 8).
3. **language**: requested = first of `$LC_MESSAGES`, `$LANG` (strip `.UTF-8`),
   else `en`. Try exact (`pt_BR`), then primary (`pt`), then `en`. v1 ships
   `en` only, so this always lands on `en` until languages are added.
4. no match → list available pages for `<pkg>` and exit non-zero.

### 3.3 `.so` redirect resolution

`.so` is a roff "source another file" request; the stubs (`vigr.8` →
`.so man8/vipw.8`) are stored as `kind=0` rather than as a 1-line roff body, to
(a) dedupe the shared target and (b) resolve **within the embedded archive**
(there is no filesystem to `.so` into). On a `kind=0` hit, look up
`(tgt_name, tgt_section, <same lang, then en>)` and render that entry. The
renderer must **also** intercept any `.so` request it encounters *inside* a roff
body and resolve it against the archive index the same way. Cap the chain at
depth 4; a cycle or dangling target → error naming the broken redirect.

---

## 4. Build side (`withMan` / `embedMan`, nix-lib)

A helper parallel to `withAliases`, applied by `mkStandaloneFlake`. No
rendering happens at build time — pages are copied as roff verbatim:

1. Collect English man pages: `$out/share/man/man[0-9]/*` (skip locale dirs).
2. For each file: gunzip if `.gz`. If the body (minus comments) is only a
   `.so <path>` request → `kind=0 (so_redirect)`, parse `(tgt_name,
   tgt_section)` from the path. Otherwise → `kind=1 (roff)`, store verbatim.
3. Build the index + blob region, zstd-compress (level 19), wrap in the outer
   container, `llvm-objcopy --add-section .unpin_man=` into the primary binary
   in `postFixup` (after strip). cosmo path as in `withAliases`.
4. Packages with no man output (busybox, coreutils, codec libs) embed nothing;
   `unpin man` reports "no embedded man for <pkg>". (coreutils/busybox could opt
   in later by enabling help2man at build — out of scope here.)

`mkman.py` is the stdlib-only builder (gunzip + zstd via CLI, pure-python crc32 —
it must run under `python3Minimal`, which lacks `zlib`). It exits 3 when the
package has no man (a skip, not a failure).

### 4.1 `embedMan` flag

`embedMan` is **default `true`** in `mkStandaloneFlake` (no users yet, so no
need to gate on the reader landing first). Per-package opt-out for the rare case
a package never wants it. Safety: when `withMan` can't find the primary binary
(a `binName` mismatch), it **warns and skips** rather than `exit 1` — worst case
is no man for that package, never a broken build.

### 4.2 Mach-O / cosmo embed mechanics

The embed mirrors `withAliases`:

- **ELF / PE**: `llvm-objcopy --add-section .unpin_man=` (readonly, noload).
- **Mach-O**: append past the code signature (`LC_CODE_SIGNATURE`), as the alias
  embed does — keeps signing valid.
- **cosmo APE**: tail-ZIP. A *functional* ZIP (cosmo libc always bundles
  `usr/share/zoneinfo/*`) → add a stored (`zip -0`) entry; a *pure* PE → truncate
  + objcopy. Auto-detected, same path as `withAliases`.

**Composition with `withAliases` (Mach-O ordering invariant):** `withAliases`
runs **first** (it truncates at the signature end), `withMan` runs **last** (it
truncates at its own man-sentinel, preserving the alias block). A post-embed
guard, `__unpin_has_meta`, asserts the alias block survives the man embed and
fails the build if it was clobbered.

### 4.3 Sourcing man for cross builds (Windows / cosmo)

Windows (mingw) and cosmo cross builds ship **no** man output. Man is OS-
independent, so `withMan` gained a `manRoot` argument and `mkStandaloneFlake`'s
windows/cosmo path embeds man sourced from the regular
`x86_64-linux.${pkgsAttr}` build (`.man or .out`) — version-locked to the same
nixpkgs pin. Validated end-to-end: jq.exe (mingw PE), tree.exe (cosmo APE,
zip-stored), xz.exe (mingw PE alias+man), all running on the Windows VM.

See [runtime-data.md](runtime-data.md) for the broader picture of how packages
that used to ship companion files now embed everything.

---

## 5. Versioning, limits, forward-compat

- Two independent version bytes: `container_version` (§1.2) and archive `magic`
  trailing byte (§2). Bump independently.
- Unknown `kind` → reader skips the entry for listing but errors clearly if it
  is the requested page ("page stored in a format this unpin can't render;
  upgrade").
- Limits: `entry_count` ≤ 65535 (u16); per-body ≤ 4 GiB (u32, never
  approached). util-linux (the worst case, 149 pages) compresses to tens of KB.
- CRC-32 is integrity-only (detect truncation/corruption), not security; the
  release pipeline already publishes `.sha256` sidecars for authenticity.
- zstd level 19 (max standard level; `--ultra -22` gains ~0). Beats gzip by
  ~9–26% on the man corpus. zstd-only; `compression=2 (deflate)` reserved but
  not emitted.

---

## 6. Renderer (`unpin man`) — design, deferred

A complete, pure-Rust roff viewer for the `.unpin_man` blob: reads the embedded
roff source, formats man(7) / mdoc(7) / tbl to the terminal, reflowing to the
live width. No C, no extracted `mandoc` binary, no build-time pre-render.

### 6.1 Why this architecture (not a full troff engine)

groff is a *general* roff interpreter; man(7)/mdoc(7) are just macro files it
loads. Re-implementing that means implementing the whole troff language
(macro definition, traps, arithmetic, diversions…). **mandoc** proved the
tractable alternative for documentation: a thin low-level roff layer (escapes,
the handful of requests real pages use, `.so`, strings/registers, conditionals)
plus **dedicated semantic parsers** for man and mdoc that build an AST, then a
backend that walks the AST. We copy that shape. It is also exactly scoped to our
catalog (man7 dominant, mdoc = 3 pkgs, tbl = 16 pages, **eqn/pic = 0**).

### 6.2 Pipeline

```
embedded roff bytes
   │  (container read + zstd decode + .so resolve — see §1, §3)
   ▼
[input]   decode, split logical lines, strip comments, join continuations
   ▼
[roff]    low-level layer: process escapes (\fB \(xx \- \& …), expand strings
          \*[..] / registers \n[..], run .if/.ie/.el .ds .de/.am .ig .nr .so,
          sniff dialect (.Dd→mdoc | .TH→man); emit resolved macro+text lines
   ▼            │ (.TS…/.TE blocks peeled off to [tbl])
[man7] / [mdoc] dialect parser → DOM
   ▼
[dom]     shared document tree (blocks + styled inline spans)
   ▼
[format]  reflow to width, indentation, fill/adjust, style→ANSI/overstrike/plain
   ▼
[pager]   $PAGER / less -R if TTY, else stdout
```

### 6.3 Module layout (keep it tight — ~6 files under `unpin/src/man/`)

| file | responsibility | phase |
|------|----------------|-------|
| `mod.rs` | `man` subcommand: arg parse (`unpin man <pkg> [sec] [page]`, `--list`), locate installed binary, read `.unpin_man` container, decompress, index lookup + `.so` resolution, drive renderer, pager | v1 |
| `roff.rs` | input normalization + low-level roff layer (escapes, strings/registers, `.if/.ie/.el/.ds/.de/.am/.ig/.nr/.so/.tr`, dialect sniff). The shared substrate man7 & mdoc sit on | v1 |
| `dom.rs` | document model (`Block`, `Inline{ text, Style }`) **+** terminal formatter (reflow, indent stack, fill/`.nf`, ANSI/overstrike/plain by `isatty`, width from `$COLUMNS`) | v1 |
| `man7.rs` | man(7) macro parser → DOM | v1 |
| `mdoc.rs` | mdoc(7) macro parser → DOM | v2 |
| `tbl.rs` | tbl preprocessor (`.TS/.TE`) → a `Block::Table` the formatter lays out | v2 |

The DOM + formatter split is what lets man7 and mdoc share one backend (and
leaves room for an HTML backend later without touching the parsers).

### 6.4 Shared DOM (`dom.rs`)

```rust
enum Block {
    Section(String, Vec<Block>),     // .SH / .Sh
    SubSection(String, Vec<Block>),  // .SS / .Ss
    Para(Vec<Inline>),               // .PP/.LP/.P, .Pp
    TaggedList(Vec<(Vec<Inline>, Vec<Block>)>), // .TP/.IP, mdoc .Bl/.It
    Indent(Vec<Block>),              // .RS/.RE
    Pre(Vec<String>),                // .nf/.fi verbatim
    Table(tbl::Table),               // v2
}
struct Inline { text: String, style: Style }      // Style: Roman|Bold|Italic|BoldItalic
```

### 6.5 v1 vs v2 capability (format is identical across both)

- **v1**: `roff.rs` + `man7.rs` + `dom.rs` + `mod.rs`. Renders man(7) and `.so`.
  Covers ~90% of catalog pages. Ships `unpin man jq` end-to-end and lets jq drop
  its data tarball. A page in a dialect not yet supported (mdoc / has `.TS`)
  **degrades gracefully**: emit lightly-cleaned roff (strip escapes, honor
  `.SH`/`.PP` coarsely) with a one-line notice, never error.
- **v2**: add `mdoc.rs` (dash, file, tmux) and `tbl.rs` (util-linux, less,
  procps, …). No format or embed change — the same stored roff now renders fully.

### 6.6 roff low-level layer — what real pages actually use (`roff.rs`)

Implement only these; ignore the rest of troff:

- **Escapes**: `\fB \fI \fR \fP \f(XX \f[..]` (fonts); `\(xx \[u00E9] \N'..'`
  (special/numeric chars → Unicode table); `\-` (minus), `\e` (`\`), `\&`
  (zero-width), `\ ` `\~` `\|` `\^` `\0` (spacing), `\c` (interrupt), `\%`
  (hyphenation hint, drop). Size/color/font-position escapes (`\s \m \f1`…):
  consume + ignore.
- **Requests**: `.\"`/`'\"` comment, `.so` (resolve in archive), `.ds/.as`
  (define/append string), `.de/.am/.ig/..` (define/append/ignore macro —
  needed: many pages define local helpers), `.nr/.rr` (register set/remove),
  `.if/.ie/.el` (conditionals — evaluate `n`/`t` and string/numeric tests well
  enough), `.tr` (translate), `.eo/.ec` (escape char). Formatting requests
  (`.br .sp .nf .fi .ad .na .in .ti .ll .ce .ne`) are passed through as DOM
  hints rather than fully simulated.
- **String/register interpolation**: `\*[name]` `\*x` `\*(xx`, `\n[name]`
  `\n(xx`. A page that `.ds`-defines a string and uses it must round-trip.

### 6.7 Terminal backend (`dom.rs`)

- Width = `min($COLUMNS, ll)`; default 80 if not a TTY / unset; user `-w N`
  override. Greedy word-wrap with hanging indents for `.TP`/lists; honor
  `.RS/.RE` indent stack; `Pre` blocks emitted verbatim (no reflow).
- Styling: TTY → ANSI SGR (`\e[1m` bold, `\e[3m`/`\e[4m` italic/underline,
  `\e[0m` reset); non-TTY → strip to plain, or backspace-overstrike if `--man`
  compat is ever wanted. Detect with `isatty(stdout)`.
- Hyphenation: none (greedy wrap only) — matches typical `MANWIDTH` terminal
  output closely enough.

### 6.8 Pager (`mod.rs`)

`$MANPAGER` → `$PAGER` → `less -R` if found on PATH and stdout is a TTY; else
write straight to stdout. Windows has no `less` by default → stdout (or a
minimal built-in pager later). Never hard-depend on an external pager.

### 6.9 Testing — the catalog is the corpus

`groff`/`mandoc` is available in the build/dev shell. Golden-test the renderer
by diffing its output against `mandoc -T utf8 -O width=80` (or `groff -man
-Tutf8`) over **every page in the catalog** (the coverage-sweep set). Not
byte-identical (spacing/hyphenation differ), but a normalized diff (collapse
runs of spaces, ignore trailing ws) must be close; track a per-page similarity
score and gate regressions. mdoc/tbl pages join the corpus when v2 lands.

### 6.10 Dependencies

Pure Rust, reuse what `unpin` already links: `ruzstd` (container decode),
nothing new for rendering. A special-char → Unicode table (`\(aa` etc.) is a
static map in `roff.rs`. No `object`/ELF crate — the container is found by the
same 0xff-sentinel byte-scan as `UNPIN_META`.
