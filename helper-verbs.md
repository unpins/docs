# Helper verbs (`unpin man`, `unpin readme`, `unpin search`, …)

unpin's command surface is **three** categories, and conflating them is what
made `unpin man` collide with the system `man`:

1. **Builtins** — `install`, `uninstall`, `run`, `info`, `list`. Logic lives in
   the `unpin` crate.
2. **Helper verbs** — `man`, `readme`, and later `changelog`, `search`,
   `license`. These *operate on* the catalog or on a package's embedded data
   (`unpin/*`, see [embedded-metadata.md](embedded-metadata.md)). A verb is
   either **builtin** — when its renderer is small or shared (`man` and `readme`
   link their engines and share one reflowing pager; see
   [embedded-man.md](embedded-man.md)) — or, when its logic is heavy and
   *independent of the pager*, shipped as its **own package** reached only through
   `unpin <verb>`. The verb *vocabulary* is unpin's either way, and a verb never
   lands on `PATH`.
3. **Programs** — the catalog (`htop`, `jq`, `tar`, …). You `run` or `install`
   them; they land on `PATH` under their real name. A program *is* what its name
   says.

A builtin verb is just a subcommand (clap parses it). **This document specifies
the verb-*package* model** — the heavy/independent case — and the naming + `PATH`
rules that keep any verb from overloading names against category 3 (the catalog)
or the OS `PATH`. man and readme began as packages under this model and proved
the renderer/pager coupling (reflow on resize) that pulled them back in as
builtins; a future `search` (a catalog index, no pager) is the kind of verb that
stays a package.

## The problem: name overload in two directions

The original man design shipped the renderer as a catalog package literally
*named* `man` (`unpins/man`), so that the existing "run the package of the same
name" dispatch would make `unpin man <pkg>` work for free. Clever, but it
overloads the name `man` two ways at once, and the cost grows with every helper
added (`readme`, `search`, `changelog`, …):

- **Against the OS.** `unpin install man` plants a `man` binary on `PATH` that
  shadows `/usr/bin/man` — and with *incompatible* semantics: the helper reads
  `man <unpin-pkg>` from the embedded bundle, never `/usr/share/man`. So
  `man ls` stops working as a user expects.
- **Against the catalog.** The name `man` is now spent. unpin can never publish a
  *real* general-purpose man, and any catalog package that happened to be named
  `man` would silently mask the helper.
- **Dispatch by coincidence.** `unpin man X` works only because a package is
  *named* `man`. The routing is implicit and fragile — nothing decides that `man`
  is a verb; it just happens to resolve.

## The model: a naming convention plus two rules

A *package* helper verb is a **normal package** — same download, cache, version,
and uninstall machinery as any catalog program. unpin gains **no per-verb
registry** and **no per-verb code**; it knows only a convention and two general
rules. (A *builtin* verb skips all of this — it's a subcommand.)

**Convention.** A package helper verb `<verb>` is the package
**`unpins/unpin-<verb>`** — e.g. `search` → `unpins/unpin-search`,
`changelog` → `unpins/unpin-changelog`. The `unpin-` prefix is self-documenting:
it marks "this is an unpin verb, not a standalone tool."

### Rule 1 — Dispatch (bare names only)

For `unpin <token> [rest…]` where `<token>` is not a builtin and contains no `/`:

1. Resolve `unpins/<token>` (a **program**). If a release exists, run it with
   `[rest…]`.
2. Otherwise — and only on a **genuine not-found** — resolve
   `unpins/unpin-<token>` (the **verb**). If it exists, run it with `[rest…]`.
3. Otherwise, error (hint both the missing package *and* the missing verb).

A `<owner>/<repo>` spec (contains `/`) is always a direct program run and
**never** enters the verb fallback.

**Why program-first.** The hot path is running a program (`unpin htop`), which
resolves `unpins/htop` and is done — the verb fallback adds **zero** cost to it,
which matters under GitHub's unauthenticated 60-requests/hour limit. The extra
probe is paid only when a verb is actually invoked. Verb-first would waste a
probe on *every* program run.

**Genuine-not-found only.** Step 2 fires solely on a real "no such release"
(HTTP 404), never on a transient failure (network down, 403 rate-limit, 5xx). A
transient error must surface as itself — otherwise a rate-limited `unpin htop`
would mysteriously try to run `unpin-htop`.

This **supersedes** the original "package of the same name" coincidence (where
`unpin man` only worked because a package was literally *named* `man`): a package
verb like a future `unpin search` resolves to `unpins/unpin-search` *by rule*, not
by a name collision. (`man` and `readme` no longer travel this path at all — they
are builtins; see the Status section.)

### Rule 2 — Helper verbs never land on `PATH`

This is the **only** way a helper is treated differently from any other package.

- **Run** (`unpin man htop`) already never touches `PATH` — `run` fetches,
  caches, and execs; it never links a bin. So the common case needs nothing
  beyond Rule 1.
- **Install** (`unpin install unpin-man`) is allowed and uses the identical
  pipeline (download, verify, store, version, uninstall) — but the linker
  **skips the `PATH` symlink** for any `unpin-*` package. Installing a verb just
  makes it **resident** (offline/fast); the dispatch then prefers the resident
  copy (cache-first) and falls back to fetching. It is never put on `PATH`, so it
  can never shadow an OS command.

That is the whole of "treated like any other package, except it doesn't go on
`PATH`."

### Naming policy (the durability guard)

The catalog **never publishes a program whose bare name equals a verb.** Once
`man` is a verb, there is no `unpins/man` *program*. This keeps program-first
dispatch (Rule 1) unambiguous and keeps the verb reachable.

This also dissolves the "but what about a *real* man?" question. A real,
general-purpose man ships under its **upstream** name — `unpins/mandoc` or
`unpins/man-db` — and installs as `man` on `PATH` via its own `binName`, by the
user's explicit choice. It and the `unpin man` verb live in different
invocations and never compete for the name:

- `unpin man htop` → the verb (`unpin-man`), renders htop's embedded page.
- `unpin install mandoc` → a real man on `PATH`, reads `/usr/share/man`.

## Why this keeps "unpin knows nothing about man"

The philosophy was always about **logic**, not **routing**. unpin still contains
no roff/markdown/search logic — that lives in each helper package. What unpin
gains is a *routing* convention (`unpin-` prefix → verb → never on `PATH`), which
is dispatch, and dispatch belongs in the CLI. Owning the verb *vocabulary* is not
the same as owning the verb *implementations*.

## How the family generalizes

A future helper drops into whichever shape fits — a **builtin** when it renders a
package's embedded data through the shared pager, or a **package** when its logic
is heavy and pager-independent:

- **`unpin changelog <pkg>`** — like readme: renders embedded `unpin/changelog/`
  markdown through the same pager. A **builtin** `Reflow` renderer (termimad is
  already linked), `0` new packages.
- **`unpin search <query>`** — operates on the *catalog*, not a bundle, so it
  needs a catalog index to exist somewhere (the website's `gen-packages.py`
  already enumerates the catalog and could emit a JSON index to consume). No
  pager coupling, so it's the natural **package** case: `unpins/unpin-search`,
  reached by the dispatch rules above and never on `PATH`.

The two shapes split by *what data the verb reads*. A **builtin** reads a
binary's embedded `unpin/*` in-process ([embedded-man.md](embedded-man.md)) —
that in-process access is exactly why man/readme are builtins, not packages. A
**package** verb operates on something external to any one binary (the catalog
index, a remote API), so it needs no access to embedded bundles — which is why
there is no longer a CLI exposing them across a process boundary. Either way
unpin's core stays small as the family grows.

## Status

- **`man` and `readme` are builtins** (2026-06-11). Each is a `Reflow` renderer
  over the shared pager in `unpin/src/render/` — `man` links the `mandoc-sys`
  crate, `readme` uses termimad — reading the embedded bundle in-process. They
  were pulled in from the `unpins/unpin-man` / `unpins/unpin-readme` packages
  (now retired) because the pager has to re-render on resize (reflow), which
  needs the renderer in-process. See [embedded-man.md](embedded-man.md).
- **The verb-*package* model stays available** for a future heavy/independent
  verb. Bare-name resolution falls back `unpins/<token>` →
  `unpins/unpin-<token>` on a genuine 404 (bare names only; see
  `verb_fallback_spec` / the run resolver in `install/mod.rs`, and
  `github::FetchError` for the 404-vs-transient distinction). `install/linker.rs`
  skips `PATH`-linking for catalog `unpins/unpin-*` packages — they install
  resident-only. The machinery is generic; man/readme simply no longer use it.
- **Catalog policy.** The naming reservation (no program may take a verb's bare
  name) is recorded in [adding-a-package.md](adding-a-package.md).
