# Crypto backend: prefer mbedtls over OpenSSL

When a static package needs a crypto/TLS backend, **swap OpenSSL for
mbedtls** (`mbedcrypto` / `mbedtls` / `mbedx509`). This is a project-wide
default, not a per-package judgement call.

## Why

- **Closure size.** In `pkgsStatic` (x86_64-musl) OpenSSL 3.x links ~4 MB
  (every provider + the post-quantum ML-DSA/SLH-DSA code), while
  `mbedcrypto.a` is ~500 KB. `nettle` (~200 KB) is also viable when a
  package supports it.
- **No double crypto.** Catalog packages that already carry mbedtls —
  `ffmpeg` enables it directly — would otherwise drag a *second*,
  redundant crypto closure through a dependency that defaults to OpenSSL.
  Keeping everyone on mbedtls means one crypto provider per binary.
- **Single-binary policy.** Smaller, single-provider closures are easier
  to keep fully static and within the [dynamic-link
  policy](dynamic-link-policy.md).

## Platform-conditional dependency

The crypto-backend flag is **safe to pass on every target**, but the
mbedtls dependency only belongs on **musl-Linux**:

- **macOS** satisfies MD5/SHA* via `LIBSYSTEM` (CommonCrypto) before any
  mbedtls/OpenSSL probe runs.
- **Windows** picks up CNG / `<wincrypt.h>` (`CRYPTO_CHECK_WIN`) the same
  way.
- **musl-Linux** has no `LIBC`/`LIBSYSTEM`/`WIN` backend, so it is the
  only target that actually links the mbedtls `.a`.

The canonical shape (libarchive/tar; the same idea drives the CMake/meson
variants below):

```nix
buildInputs = (old.buildInputs or [ ])
  ++ pkgs.lib.optional pkgs.stdenv.hostPlatform.isLinux pkgs.pkgsStatic.mbedtls;
configureFlags = (old.configureFlags or [ ]) ++ [
  "--without-openssl"
  "--with-mbedtls"
];
```

Without an explicit backend on Linux the hash functions degrade to stubs
returning failure — e.g. libarchive loses mtree `sha256digest`, encrypted
ZIP/7z read, and xar hash verification (plain tar/gzip/xz/zstd/bzip2 are
unaffected).

**Cross-mingw caveat:** mbedtls's `threading.h` includes `<pthread.h>`, so
a cross-mingw build needs `windows.pthreads` in `buildInputs`. Either keep
mbedtls Linux-only (the conditional above) or add winpthreads.

## How each consumer selects it

The flag name differs per build system; the buildInputs/propagation
mechanics are the same swap. Per-package mechanics stay in the overlay /
consumer flake — this table is the index.

| Package | Selector | Overlay / flake |
| --- | --- | --- |
| `tar` (libarchive) | `--without-openssl --with-mbedtls` | `tar/flake.nix` |
| `srt` | `-DUSE_ENCLIB=mbedtls` | `nix-lib/native-overlay/srt.nix` |
| `libssh` | `-DWITH_MBEDTLS=ON` | `nix-lib/native-overlay/libssh.nix` |
| `librist` | upstream defaults to `mbedcrypto` | `nix-lib/native-overlay/librist.nix` |

### The `.pc` tail that recurs with this swap

Swapping to a static mbedtls almost always exposes one of two
`pkg-config --static` traps — both covered in
[static-linking.md](static-linking.md):

- CMake bakes **absolute** `/nix/store/.../libmbed*.a` paths into
  `Libs.private`; a `--static` consumer routes them to ldflags *before*
  the test object, where `-Wl,--as-needed` drops them. Rewrite to `-l`
  form (`srt`).
- The crypto backend is left **out of `Requires.private` / `Requires`**
  entirely, so consumers fail with `mbedtls_*` undefined. Append the line
  (`libssh`); or propagate the dep so the public `Requires:` traversal
  resolves (`librist`).

## Exception: rtmpdump keeps OpenSSL

`rtmpdump` only offers OpenSSL / GnuTLS / PolarSSL backends — PolarSSL is
the *pre-3.x* mbedtls, incompatible with nixpkgs' mbedtls 3.x — so there is
no mbedtls path. The standalone `unpins/rtmpdump` therefore keeps
`CRYPTO=OPENSSL` (the working full-feature option for `rtmpe://` /
`rtmpte://`). It does **not** double up inside ffmpeg: ffmpeg drops
`--enable-librtmp` and uses its *native* rtmp/rtmpe/rtmps protocols, which
do crypto via the mbedtls ffmpeg already links (`rtmpdh.c`
`CONFIG_MBEDTLS`). librtmp would only add a dep and subtract working
crypto.
