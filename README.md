# unpins documentation

The source of truth for non-trivial work in the unpins workspace. The sibling [CLAUDE.md](CLAUDE.md) (and any per-tool memory) only summarizes — when in doubt, read here.

## When to read what

- **Adding a new package**: start with [adding-a-package.md](adding-a-package.md).
- **Understanding the build glue**: [architecture.md](architecture.md) explains `mkStandaloneFlake`, the `fixes` registry in `nix-lib`, and when to extend `nix-lib` vs keep the override inline.
- **The single-binary rule**: [dynamic-link-policy.md](dynamic-link-policy.md) lists what each OS is allowed to load dynamically, and how CI enforces it.
- **A package needs data files at runtime**: [runtime-data.md](runtime-data.md) (vim/gvim/file pattern).
- **Writing a source patch**: [patches.md](patches.md) — gotchas that have cost time, plus the rule "always regenerate via `diff -u`, never hand-edit".

## Platforms

Each page consolidates known gotchas and dead ends, so you don't re-discover them:

- [platforms/mingw.md](platforms/mingw.md) — POSIX shim gaps, static-link pitfalls (libidn2/libpsl chain, fake-static libraries), packages that cannot cross-build via mingw.
- [platforms/darwin.md](platforms/darwin.md) — `pkgsStatic` semantics, cross-from-aarch64 pattern, overlay cascade, the `fake-cross` dead end.
- [platforms/cosmocc.md](platforms/cosmocc.md) — Cosmopolitan toolchain, `cosmoStdenv` pattern, when to reach for it instead of mingw.

## Recipes

- [big-packages.md](big-packages.md) — playbook for `ffmpeg`-class packages with large dependency graphs.

## Templates

- [templates/flake.nix](templates/flake.nix) — minimal per-package flake.
- [templates/build.yml](templates/build.yml) — per-package CI build workflow.
- [templates/release.yml](templates/release.yml) — release workflow.

## Source of authority

When two places disagree, the order is:

1. The actual code in the workspace (`nix-lib/flake.nix`, the consumer flakes).
2. Documents here.
3. [CLAUDE.md](CLAUDE.md).
4. Any auto-memory.

Memory is point-in-time and may name files or flags that have since moved; verify before relying on it for the current state.
