# Helper verbs (`unpin man`, `unpin readme`, `unpin search`, …)

unpin's command surface is **three** categories, and conflating them is what
made `unpin man` collide with the system `man`:

1. **Builtins** — `install`, `uninstall`, `run`, `info`, `list`, `bundle`. Logic
   lives in the `unpin` crate.
2. **Helper verbs** — `man` today; `readme`, `changelog`, `search`, `license`
   later. These *operate on* the catalog or on a package's embedded data
   (`unpin/*`, see [embedded-metadata.md](embedded-metadata.md)). Their logic is
   too heavy or too domain-specific to live in unpin (a roff renderer, a markdown
   renderer), so each is shipped as its **own package** and reached only through
   `unpin <verb>`.
3. **Programs** — the catalog (`htop`, `jq`, `tar`, …). You `run` or `install`
   them; they land on `PATH` under their real name. A program *is* what its name
   says.

This document specifies how category 2 works without overloading names against
category 3 (the catalog) or against the OS `PATH`.

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

A helper verb is a **normal package** — same download, cache, version, and
uninstall machinery as any catalog program. unpin gains **no per-verb registry**
and **no per-verb code**; it knows only a convention and two general rules.

**Convention.** A helper verb `<verb>` is the package **`unpins/unpin-<verb>`**.
`man` → `unpins/unpin-man`, `readme` → `unpins/unpin-readme`,
`search` → `unpins/unpin-search`. The `unpin-` prefix is self-documenting: it
marks "this is an unpin verb, not a standalone tool."

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

This **supersedes** the "package of the same name" coincidence in the current
[embedded-man.md](embedded-man.md) flow: `unpin man` resolves to
`unpins/unpin-man` by rule, not because a package named `man` happens to exist.

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

Every future helper drops into the same shape — `+1` package, `0` lines of
verb-specific unpin code:

- **`unpin readme <pkg>`** — symmetric with man: reads `unpin/readme/README.md`
  from the bundle via `unpin bundle dump` (with a repo fetch as fallback) and
  renders markdown. Package `unpins/unpin-readme`.
- **`unpin changelog <pkg>`** — same, `unpin/changelog/`.
- **`unpin search <query>`** — operates on the *catalog*, not a bundle, so it
  needs a catalog index to exist somewhere (the website's `gen-packages.py`
  already enumerates the catalog and could emit a JSON index for
  `unpin-search` to consume). The dispatch/`PATH` treatment is identical; only
  the data source differs. Package `unpins/unpin-search`.

All of them read package data through the **stable** `unpin bundle list|dump`
interface ([embedded-man.md](embedded-man.md)), so unpin's core stays tiny as the
family grows.

## Status & migration

This is the **target** model; the steps below are not all done yet. Current
reality (the `unpins/man` coincidence) is still what [embedded-man.md](embedded-man.md)
describes.

- **`unpin` crate.** Add the verb fallback to bare-name resolution
  (`unpins/<token>` → `unpins/unpin-<token>`, gated on a genuine 404, bare names
  only; see `parse_args` / the run resolver in `main.rs`). Skip `PATH`-linking
  for `unpin-*` packages in `install/linker.rs`.
- **The man package.** Republish `unpins/man` as **`unpins/unpin-man`** and retire
  the old `unpins/man` releases (otherwise program-first dispatch resolves the old
  helper as a "program"). The `binName` stops mattering — it is never linked.
  Update [embedded-man.md](embedded-man.md) once this lands.
- **Catalog policy.** Record the naming reservation (no program may take a verb's
  bare name) in [adding-a-package.md](adding-a-package.md).
