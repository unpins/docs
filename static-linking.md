# pkgsStatic gotchas (cross-cutting)

`pkgs.pkgsStatic.<name>` (musl, fully static) is the default native build path. It breaks in ways that intuition from dynamic distros doesn't predict. Platform-specific behavior lives in [platforms/darwin.md](platforms/darwin.md) (no global `-static`, the `--enable-static` misinterpretation) and [platforms/mingw.md](platforms/mingw.md) (the static-link toolbox). This page collects the traps that are **independent of OS** and recur across packages.

See also [big-packages.md](big-packages.md) for the cache-aware rule (*don't* add `--disable-shared` to a lib that `pkgsStatic` already builds static — it's a needless cache miss).

## Propagation & outputs

- **`pkgsStatic` auto-promotes `buildInputs` → `propagatedBuildInputs`.** Override *both* or the old (dynamic) closure stays. Verify with `nix derivation show … | jq '.[].env.propagatedBuildInputs'`. (`feedback_pkgsstatic_propagated_buildinputs`)

- **Multi-output libs propagate only `out`, not `lib`/`dev`.** The `.pc` files and CMake config live in `.dev`. `pkg_search_module` / `find_package` then *silently* fail to find them — CMake prints `Library: missing` with no error, configure continues, the feature is quietly dropped. Add `pkg.dev` explicitly to `buildInputs`. (`feedback_pkgsstatic_multi_output_propagation`)

- **Use `self.X`, not `super.X`, when propagating a modified dep inside an overlay.** `super.X` is the pre-overlay vanilla derivation; referencing it creates a *second* phantom copy of the lib that coexists with the fixed one, and the consumer links the wrong one. Symptom: a fix that's clearly applied still doesn't take (two drvs of the same lib in the closure). (`feedback_overlay_self_vs_super`)

## `.pc` files and the static linker

- **C++ libs that omit `Libs.private: -lstdc++ -lm`** link fine dynamically but fail under `pkg-config --static` (the consumer never pulls the C++ runtime). Fix in `postInstall`: `echo 'Libs.private: -lstdc++ -lm' >> $out/lib/pkgconfig/<lib>.pc`. (`feedback_pkgsstatic_cpp_lib_no_libs_private`)

- **`Requires.private` is dropped by consumers that don't pass `--static`** (a structural nixpkgs gap): the transitive `.pc` isn't traversed, so a `pkg-config <lib>` version probe reports "not found". Double fix: sed `Requires.private:` → `Requires:` in the `.pc` **and** propagate the dep. Cases: brotli, fontconfig, libtiff, libthai, glib. (`feedback_requires_private_static_cross` — and the mingw provider-side variants in [platforms/mingw.md](platforms/mingw.md).)

- **Upstream LTO=ON leaves the archive as pure IR** (`__gnu_lto_slim`); a non-LTO consumer's `ld` fails with `undefined reference` it can't see. Override the project's LTO knob OFF (e.g. `-DSVT_AV1_LTO=OFF`) when the consumer doesn't link with the LTO plugin. (`feedback_pkgsstatic_lto_archive_trap`) Unblocked svt-av1 cross-mingw.

## DCE is *much* more aggressive than you expect

Static link + `ld --gc-sections` (and LTO) prune with full whole-program visibility. Pulling in a "heavy" lib (X11 chain `+27 KB`, glib chain `+4 KB`, Vulkan+OpenCL `+5 KB` in fastfetch) is often nearly free — the "this lib is expensive" intuition comes from dynamic distros where nothing is pruned. Heuristic: a **narrow API surface = DCE-friendly**; a lib whose work happens through an internal **plugin/`dlopen`** path becomes a silent stub on musl (the dlopen returns NULL, the feature no-ops) rather than a link error. Test the actual size before disabling a feature to "save space". (`feedback_pkgsstatic_dce_is_aggressive`)

## Eval-time blockers

- **`nativeCheckInputs` can block *eval*** even when you intend to skip tests — a check input like `SDL2` / `gtest` carries `badPlatforms` that rejects the static platform before `doCheck` is consulted. Set `doCheck = false` (or `doInstallCheck = false`, depending on which phase pulls it) on the derivation; for a transitive consumer, apply via an overlay `extend`. (`feedback_pkgsstatic_test_input_blocking_eval`)

- **Check `meta.badPlatforms.isStatic` first.** Some libs (`libglvnd`, `libpulseaudio`) are explicitly marked unsupported under static and will never eval — don't burn time trying to override them; find the static-friendly alternative or stub.

## Toolchain / probe quirks

- **`AC_FUNC_MALLOC` / `AC_FUNC_REALLOC` fail on musl** (musl's `malloc(0)` returns NULL, which the test treats as broken), then autoconf `#define malloc rpl_malloc` — but `rpl_malloc` only exists if the package vendors gnulib, so the link fails on `rpl_malloc` undefined. Two-line fix: `configureFlags += [ "ac_cv_func_malloc_0_nonnull=yes" "ac_cv_func_realloc_0_nonnull=yes" ]`. Applies to any old autoconf package cross-musl. (`feedback_autoconf_rpl_malloc_musl`)

- **Splicing: use `scope.X`, not `scope.buildPackages.X`, in `nativeBuildInputs`.** The splicing-aware `scope.X` lets the cross machinery pick the right triple; `buildPackages.X` disables splicing and can resolve to the wrong one. (`feedback_nixpkgs_splicing_native_build_inputs`)

- **Rust + musl emits `-lunwind`.** meson/CMake projects that probe `rustc --print=native-static-libs` get `-lunwind` and the `find_library` check fails. Add `pkgsStatic.libunwind` to `buildInputs` (~250 KB). (`feedback_pkgsstatic_librsvg_rust_musl_unwind`, librsvg)

- **`polyfill-glibc` LOAD segments get destroyed by `fixupPhase`.** `patchelf --shrink-rpath` + `strip` drop the LOAD headers polyfill injected. Set `dontPatchELF = true; dontStrip = true;` on the derivation that applies polyfill. (`feedback_polyfill_glibc_fixup_trap`)

## Heavier patterns (when a leaf dep won't go static)

- **Two-libc build.** A package with a glibc-dynamic build-time helper + a musl-static main binary must be **two separate `mkDerivation`s** — the `pkgsStatic` cc-wrapper's `-static` bleeds across a single derivation's phases. Build the helper in a plain (glibc) derivation, consume it by absolute path (`${helper}/bin/x`) from the static main. (`feedback_two_libc_nix_build`)

- **ICD dispatchers** (`vulkan-loader`, `ocl-icd`) need: sed `SHARED` → `STATIC` in their CMake, drop `install(EXPORT …)`, and nuke the `noinst_PROGRAMS` test that links strong+weak copies of the same symbol. (`feedback_pkgsstatic_icd_dispatcher_patches`)

These are terse on purpose — each links an auto-memory file with the full reasoning and the exact diff.
