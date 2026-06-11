# unpins documentation

These are the internal docs for the [unpins](https://unpins.org) workspace — the build glue, per-platform gotchas, and recipes that produce the single-binary programs published on the site.

## Getting started

- **Contributing for the first time?** [contributing.md](contributing.md) explains which repo owns what and the conventions to follow.
- **Adding a new package?** Walk through [adding-a-package.md](adding-a-package.md) — an end-to-end checklist from `flake.nix` scaffolding to first release.
- **Understanding the build glue?** [architecture.md](architecture.md) covers `mkStandaloneFlake`, where per-binary quirks live (inline) vs. transitive-library fixes (`nativeFixes` + the `native-overlay` / `mingw-overlay` / `cosmo` fragments), and when to extend `nix-lib` versus keep an override inline.
- **Cutting a release?** [releasing.md](releasing.md) — tag format, the Build/Release workflow split, Cachix, common failure modes.

## Project rules

- [dynamic-link-policy.md](dynamic-link-policy.md) — the **single-binary rule** every artifact must satisfy, and how CI enforces it per OS.
- [messaging.md](messaging.md) — how we **describe** unpins externally: slogan, the canonical project/package sentences, vocabulary, and which surface leads with what. Source of truth for all external copy.

## Per-platform reference

Cumulative logs of gotchas, dead ends, and known fixes — so the next person doesn't re-discover them.

- [platforms/mingw.md](platforms/mingw.md) — Windows cross-builds: POSIX shim gaps, the libidn2 / libpsl / libunistring / libiconv static-link chain, fake-static libraries, and the packages that don't take the mingw path (`bash` and `coreutils` ship via cosmo; `git` is a mingw WIP).
- [platforms/darwin.md](platforms/darwin.md) — macOS: how `pkgsStatic` behaves on darwin, the cross-within-darwin pattern, the overlay-cascade pitfall, and two abandoned approaches.
- [platforms/cosmocc.md](platforms/cosmocc.md) — Cosmopolitan toolchain: when to reach for it, the `cosmoStdenv` pattern, packaging mechanics, and the `ahgamut/superconfigure` reference.

## Recipes

- [patches.md](patches.md) — patch-writing gotchas: regenerate via `diff -u` (and why hand-edited hunks fail silently), nixpkgs path-style headers, where to apply the patch (consumer flake vs. a `native-overlay` / `mingw-overlay` / `cosmo` fragment), fake-static library construction, symbol-collision recipe for whole-program embedding.
- [runtime-data.md](runtime-data.md) — packages that need data files at runtime (`vim`, `gvim`, `file`). The two embedding patterns (compiled-in blob; embedded ZIP + in-tool VFS), with the opt-in `package_data` companion archive + relative-to-exe lookup as the fallback.
- [embedded-metadata.md](embedded-metadata.md) — the unified `unpin/` ZIP container embedded in every binary (aliases + man pages today), the byte-scan locator, and the `withAliases`/`withMan` build glue that produces it.
- [embedded-man.md](embedded-man.md) — how `unpin man` works: the roff is embedded per package (killing the man-only data tarballs), and `unpin man` is a builtin that renders it in-process via the vendored render-only `mandoc-sys` crate, paged by `unpin/src/render/` (the `unpin bundle list|dump` interface stays for independent verb-packages).
- [helper-verbs.md](helper-verbs.md) — the model for `unpin`'s verb commands: a verb is **builtin** when its renderer is small/shared (`man`, `readme` — folded in for in-process reflow) or a `unpins/unpin-<verb>` package (e.g. a future `search`) reached only via `unpin <verb>`, never on `PATH`, with the dispatch precedence and catalog naming reservation that stop the verb name from colliding with the OS or the catalog.
- [big-packages.md](big-packages.md) — playbook for `ffmpeg`-class packages with large dependency graphs, plus the static GTK2 recipe used by `gvim`.
- [crypto-backend.md](crypto-backend.md) — why packages swap OpenSSL for mbedtls, the platform-conditional dependency, the per-consumer selector table, and the rtmpdump exception.
- [testing.md](testing.md) — per-package × per-OS test-suite matrix: invocation, runtime deps (msys2/brew/nixpkgs), Linux/macOS/Windows quirks, rollout order.

## Templates

Drop-in starting points for new package repos:

- [templates/flake.nix](templates/flake.nix) — minimal per-package flake.
- [templates/build.yml](templates/build.yml) — per-package CI build workflow.
- [templates/release.yml](templates/release.yml) — release workflow.

---

[`CLAUDE.md`](CLAUDE.md) is a slim summary of the project rules tailored for Claude Code and other AI agents working in the workspace. It points back to the documents above for anything non-trivial.

## Source of authority

When two sources disagree:

1. The actual code (`nix-lib/flake.nix` and the consumer flakes).
2. Documents in this directory.
3. `CLAUDE.md`.
4. Auto-memory snapshots (point-in-time, may be stale).
