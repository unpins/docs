# Contributing

unpins is a multi-repo workspace; contributions land in whichever repo owns the thing you're changing.

## Where to file what

| Type of contribution | Repo |
| -------------------- | ---- |
| A bug in an unpins-built binary, or a packaging fix | The package's own repo (e.g. [`unpins/htop`](https://github.com/unpins/htop)). |
| A new package proposal | Open an issue in [`unpins/docs`](https://github.com/unpins/docs) first to align on scope and platform feasibility, then push the new package as its own repo. |
| The `unpin` CLI itself (the installer) | [`unpins/unpin`](https://github.com/unpins/unpin). |
| Shared build helpers / `fixes` registry | [`unpins/nix-lib`](https://github.com/unpins/nix-lib). |
| CI workflows | [`unpins/action-build`](https://github.com/unpins/action-build). |
| Website content | [`unpins/website`](https://github.com/unpins/website). |
| These docs / architecture / patch recipes | [`unpins/docs`](https://github.com/unpins/docs). |

## Proposing a new package

Two questions before you start:

1. **Does upstream already do what we'd do?** If `<owner>/<repo>` already publishes portable single-binary releases — `ripgrep` is the canonical example, with musl-static Linux, native macOS, and `.exe` for Windows on every tag — then `unpin install <owner>/<repo>` already works. **Don't package it.** The catalog exists for programs whose upstream doesn't ship this way.
2. **If we do need to package it, is it feasible?** Some upstream architectures don't reduce to a single binary (see [dynamic-link-policy.md](dynamic-link-policy.md), [platforms/mingw.md](platforms/mingw.md), and [platforms/cosmocc.md](platforms/cosmocc.md) for the known dead ends and escape hatches).

If both check out, the path is [adding-a-package.md](adding-a-package.md). The checklist there is the path that's already worked for the existing catalog.

## Commit conventions

- Subject line ≤ 70 chars. The body explains *why* the change is needed, not what the diff shows.
- Reference the upstream behavior that motivated a patch in the patch's leading comment block — see [patches.md](patches.md).
- AI-assisted commits carry the trailer:

  ```
  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  ```

## Code conventions (Nix)

- Per-package quirks live in [`nix-lib`'s `fixes` registry](architecture.md#the-fixes-registry), not as conditionals inside the consumer flake.
- When a quirk is genuinely one-off (a custom `Make_ming.mak`, a one-line `substituteInPlace`), keep it inline in the consumer flake — don't promote it to a helper.
- The "≥ 2 callers today" rule applies (see [`nix-lib` scope](architecture.md#nix-lib-scope)) — speculative abstractions stay out of `nix-lib`.

## Patches

If you need to patch upstream source: **always regenerate the patch via `diff -u`**. Hand-editing hunk headers is the single most common way to ship a build that succeeds but silently drops half the patch. See [patches.md](patches.md) for the full set of gotchas, including the fake-static-library recipe and the symbol-collision workaround for whole-program embedding.

## Review

There is no monorepo CI — each repo runs its own Build workflow on push, which is the first gate. A maintainer will weigh in on style, architecture, and merge.

For changes that span multiple repos (e.g. a new helper in `nix-lib` that several packages will adopt), land the `nix-lib` change first, then bump `flake.lock` in each consumer as a separate PR.

## After merging

If your change adds a new package or bumps an existing one, see [releasing.md](releasing.md) for the post-merge release flow.
