# unpins

Native single-binary builds of common programs — `htop`, `jq`, `curl`, `tmux`, `tree`, `vim`, `gvim`, `coreutils`, `tar`, `file` — plus a Rust installer (`unpin`) that downloads them from GitHub releases. Each shipped artifact is one executable per OS, no third-party DLLs, no `/nix/store` closure at runtime.

Website: <https://unpins.org>. GitHub org: <https://github.com/unpins>.

## Workspace

Each top-level directory is an **independent git repo**:

- `unpin/` — Rust CLI installer.
- `nix-lib/` — shared `mkStandaloneFlake` + cosmocc toolchain (`lib.cosmoStdenv`; wires `pkgs.pkgsCross.cosmo` as a first-class cross target inside `windowsPkgs`) + cross overlay fragments (`native-overlay/`, `mingw-overlay/`, `cosmo/`). Per-binary quirks live inline in each consumer flake.
- One directory per package flake (e.g. `htop/`, `tree/`) — the [packages page](https://unpins.org/packages.html) has the current catalog.
- `action-build/` — reusable GitHub Actions workflows.
- `website/` — site source.
- `playground/<pkg>/` — work-in-progress packages (not consumed by `unpin` or the website). Each one is its own repo when ready for release; `playground/` itself is not.

Each pkg dir is its own repo — commit and push there, **not** from the workspace root.

## Non-negotiables

- **Single binary, no companion DLL/dylib/so.** Per-OS allow-list and CI enforcement: [dynamic-link-policy.md](dynamic-link-policy.md).
- **Per-binary quirks live inline in the consumer flake** — `build` / `windowsBuild` closures for native/mingw, a `./cosmo.nix` sidecar invoked via `windowsBuild = import ./cosmo.nix { inherit unpins-lib; }` for cosmocc — not in `nix-lib`. Shared library-dep tweaks consumed transitively by other packages live in `nix-lib/{native-overlay,mingw-overlay,cosmo}/<lib>.nix` (auto-discovered via `readDir`).
- **GitHub repo description = `flake.nix` `description` verbatim** at repo creation:
  ```
  gh repo create unpins/<pkg> --public \
    --description "$(grep -oP '(?<=^  description = ")[^"]+' flake.nix)"
  ```
- **The `unpin` Rust crate stays lint-clean.** Before every commit, both
  `cargo fmt --check` and `cargo clippy --all-targets` must pass with **zero
  warnings** — for the host target **and** the Windows cross-target
  (`cargo clippy --target x86_64-pc-windows-gnu --all-targets`), since a chunk
  of the code is `cfg(windows)`-only and never compiled by the host build.
  Reach for a scoped `#[allow(...)]` with a one-line justification only when a
  lint is a genuine false positive — never a crate-wide `allow`.

## Documentation

This file lives inside the `docs/` repo (`github:unpins/docs`); the rest of the documentation sits next to it. Read here before re-investigating any platform issue.

- [contributing.md](contributing.md) — where contributions go (multi-repo), conventions, commit trailer.
- [adding-a-package.md](adding-a-package.md) — checklist when scaffolding a new package.
- [releasing.md](releasing.md) — release flow, tag format, common failure modes.
- [architecture.md](architecture.md) — `mkStandaloneFlake`, where per-binary quirks live (inline) vs. transitive-lib overlay fragments (`nix-lib/{native,mingw}-overlay/`, `nix-lib/cosmo/`), `nix-lib` scope rule, refactor verification.
- [dynamic-link-policy.md](dynamic-link-policy.md) — what each OS may load dynamically.
- [messaging.md](messaging.md) — source of truth for external copy: slogan, the canonical project/package sentences, vocabulary (`programs` not `tools`; `self-contained` not `static`), per-surface hero emphasis.
- [static-linking.md](static-linking.md) — `pkgsStatic` gotchas independent of OS (propagation, `.pc`/`Requires.private`, aggressive DCE, eval blockers, musl probes).
- [runtime-data.md](runtime-data.md) — packages with data files (vim, gvim, file pattern).
- [embedded-metadata.md](embedded-metadata.md) — the unified `unpin/` ZIP container embedded in every binary (aliases + man), byte-scan locator, `withAliases`/`withMan` glue, alias security model.
- [embedded-man.md](embedded-man.md) — `unpin man` dispatches to the `unpins/man` package (patched mandoc), which reads embedded roff via the stable `unpin bundle list|dump` interface; unpin itself renders nothing.
- [helper-verbs.md](helper-verbs.md) — the durable model for `unpin man`/`readme`/`search`/… : helpers are `unpins/unpin-<verb>` packages reached only via `unpin <verb>`, never on `PATH`; dispatch precedence and the catalog naming reservation that keep the verb name from colliding with the OS or the catalog.
- [patches.md](patches.md) — patch-writing gotchas (regenerate via `diff -u`; where to apply; fake-static libs; symbol-collision recipe).
- [multicall.md](multicall.md) — folding many upstream executables into one `argv[0]`-dispatching binary (`ld -r` and reuse-the-link-line recipes).
- [platforms/mingw.md](platforms/mingw.md) — POSIX shim gaps, static-link pitfalls, fake-static libs, mingw blockers (bash/coreutils ship via cosmo; git is a mingw WIP).
- [platforms/darwin.md](platforms/darwin.md) — `pkgsStatic` semantics, cross within darwin, overlay cascade, dead ends.
- [platforms/cosmocc.md](platforms/cosmocc.md) — Cosmopolitan + `superconfigure` for mingw-blocked packages + first-class `pkgs.pkgsCross.cosmo` (wired via `applyPatches` + `replaceCrossStdenv` in `windowsPkgs`).
- [big-packages.md](big-packages.md) — ffmpeg-class playbook; static GTK2 recipe.
- [crypto-backend.md](crypto-backend.md) — prefer mbedtls over OpenSSL for static crypto: why, platform-conditional dep, per-consumer selectors, rtmpdump exception.
- [templates/](templates/) — minimal `flake.nix`, build/release workflow files.

## Commits

AI-assisted commits carry the trailer:

```
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

## Source of authority

When two places disagree, the order is:

1. The code in the workspace itself (`nix-lib/flake.nix`, consumer flakes).
2. The documents in this directory.
3. This file.
4. Auto-memory (point-in-time, may be stale — verify before relying on it).
