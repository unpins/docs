# Messaging

The single source of truth for how we **describe** unpins to the outside world —
slogan, the canonical sentences, vocabulary, and which surface leads with what.
When the website, the org profile, a package README, or a release disagree on
wording, this file wins. Copy from here; don't re-invent per surface.

This governs *external copy*. The build/technical truth lives in the other docs
(e.g. [static-linking.md](static-linking.md), [architecture.md](architecture.md));
this file only governs how we phrase it.

## Slogan

> **Unpin your programs from your OS**

## The two canonical sentences

Almost all the repeated copy is one of these two. Nail them and most drift
disappears.

**Project sentence** — org profile, site home, top of a release:

> Common programs as single self-contained binaries, built natively for Linux,
> macOS, and Windows. unpins curates and builds them; the `unpin` CLI installs
> them, or anything from a GitHub release.

**Package-README sentence** — the opening line of every package repo's README
(swap in the program name):

> **htop** as a single self-contained binary, built natively for Linux, macOS,
> and Windows — part of the [unpins](https://unpins.org) catalog. Install it with
> [`unpin`](https://github.com/unpins/unpin): `unpin install htop`.

The project sentence sells the *catalog*; the package sentence sells *that one
program*. They are deliberately different — don't collapse them into one.

## Positioning

- **The catalog is the differentiator** — curated programs we build ourselves as
  self-contained binaries, one per OS, reproducibly. This is the part nothing
  else in the space does; it's the gem.
- **The `unpin` CLI is the installer** — fetches a GitHub release asset, verifies
  its SHA256, then runs it or puts it on `PATH`. In *mechanism* it's comparable
  to `eget` / `ubi` / `dra`; the catalog is what makes unpins different.
- **`run` is the default** — a name with no subcommand fetches-and-runs the
  program once, installing nothing. Putting it on `PATH` is the explicit
  `unpin install`.

### Emphasis is surface-dependent (by design, not drift)

The shared core — slogan, the two sentences, vocabulary — is identical
everywhere. Only the *hero* shifts, to match what each surface is about:

| Surface | Hero leads with | Sentence |
| --- | --- | --- |
| Org profile (`.github/profile`) | the **catalog** | project sentence |
| Site home (`index.html`) | the **catalog** | project sentence |
| Site `why.html` | the **catalog** (catalog vs CLI, in depth) | its own long form |
| `unpin` README | the **CLI** (that repo *is* the CLI) | project sentence, catalog block right after |
| Release notes | the **CLI** (that's the artifact shipping) | project sentence, strong catalog block after — v0.3.0 is the model |
| Package READMEs | **that program** | package sentence |

A release or the CLI README leading with the CLI is **correct**, not an
inconsistency — as long as the catalog gets a strong block right after and the
shared core matches.

## Vocabulary

**Use:**

- **programs** — never "tools", "CLI tools", or "utilities". (unpins ships GUIs
  like `gvim` too.)
- **single self-contained binary** — never "static binary". macOS links Apple's
  `libSystem`, so "static" is false there; "self-contained" is true on all three.
- **built natively for Linux, macOS, and Windows** — never "one build" or "runs
  unchanged" across OSes. One *recipe* produces a *native binary per OS*; we are
  **not** Cosmopolitan/APE (one binary for all OSes). Say nothing that implies a
  universal binary.
- **unpins** (lowercase) = the project / org / catalog. **`unpin`** (code) = the
  CLI binary.
- **catalog** = the curated set; **any GitHub release** = the general capability.
- **multicall packages** — a package may be a single program (`htop`) or a
  multicall binary that bundles many (`coreutils`, `busybox`). The unit is the
  **binary**, not the program — "single self-contained binary" holds either way.
  Never say "one program per repo"; the per-repo invariant is one flake, one
  binary.

**Names — the resolved "bare name" collision.** The term "bare name" was used for
two different things; retire it. Use instead:

- **catalog name** — a name with no owner (`htop`, `jq`); resolves to
  `unpins/<name>`.
- **full repo** — `owner/repo[@version]` (`BurntSushi/ripgrep`); any GitHub
  release.
- **the default `run` action** — a name with no *subcommand* runs the program
  once. Describe it this way; never call it a "bare name".

## The standard example block

Shows all three axes (run vs install, catalog vs any repo) in three lines:

```sh
# Run once — nothing is installed (the default action)
unpin ffmpeg -version

# Install from the catalog (a catalog name resolves to unpins/<name>)
unpin install htop

# Install from any GitHub release (a full owner/repo)
unpin install BurntSushi/ripgrep
```

## Pitch tiers

- **One line** — profile top, README blockquote: the slogan, or a compressed
  project sentence.
- **One paragraph** — release top, site hero: the project sentence.
- **Full** — `why.html`: the whole story with nuance (single-binary policy,
  reproducibility, scope and limits, how-to-verify).

## Demos

GIF is being phased out for program demos: 256-color banding distorts terminal
output, it doesn't scale, and files are large. Prefer self-contained crisp
formats:

- **Terminal motion (e.g. a TUI like `htop`)** — `<video>` (webm/mp4) on the
  site; an animated SVG (e.g. `svg-term`) for GitHub READMEs, which renders
  inline and stays crisp.
- **Command → output, no motion needed** — a styled `<pre>` block on the site, a
  fenced code block in a README. Zero distortion, copy-pasteable, theme-aware.

Recordings are produced with `vhs` (see the demo recipe); `vhs` emits
webm/mp4/frames as well as gif, so the source pipeline already exists. The exact
replacement format is not yet locked.
