# Crypto backend: prefer mbedtls over OpenSSL

When a static package needs a crypto/TLS backend, **swap OpenSSL for
mbedtls** (`mbedcrypto` / `mbedtls` / `mbedx509`). This is a project-wide
default, not a per-package judgement call.

## Why

- **Closure size.** In `pkgsStatic` (x86_64-musl) OpenSSL 3.x links ~4 MB
  (every provider + the post-quantum ML-DSA/SLH-DSA code), while
  `mbedcrypto.a` is ~500 KB. `nettle` (~200 KB) is also viable when a
  package supports it.
- **No double crypto.** A package that already carries one crypto library
  would otherwise drag a *second*, redundant one through a dependency that
  defaults to something else. One crypto provider per binary, whichever
  it is — `ffmpeg` is on OpenSSL (see the exception below), so its
  dependencies follow it there.
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
| `srt` | `-DUSE_ENCLIB=mbedtls` (`.withOpenssl` keeps OpenSSL, for ffmpeg) | `nix-lib/native-overlay/srt.nix` |
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

## Exception: ffmpeg uses OpenSSL

FFmpeg's TLS verification (`-tls_verify 1`) needs CA roots. Its mbedtls
backend reads only an explicit `-ca_file`, so with mbedtls verification
rejected every server unless the user found and passed a bundle. Its
OpenSSL backend loads OpenSSL's default verify paths, which
`lib.retargetOpenssl` points at the host's bundle, with Mozilla's roots
embedded as the fallback (and always used on Windows). So `ffmpeg` builds
`--enable-openssl` (OpenSSL 3 needs `--enable-version3`, which it already
passes), and its crypto dependencies follow it:

- `srt` uses `nativeFixes.srt.withOpenssl`;
- `libssh` (ffmpeg is its only consumer) is on OpenSSL with
  `-DWITH_NACL=OFF`, since OpenSSL already covers curve25519 and ed25519
  — `nix-lib/native-overlay/libssh.nix`;
- `librist` stays on `mbedcrypto`: it has no OpenSSL backend, and its
  built-in AES alternative drops SRP authentication. That is the one
  second crypto library in the binary.

The native engine scopes get `retargetOpenssl` from nix-lib; the mingw
scope does not, so `ffmpeg`'s `windowsBuild` applies it with `C:/ssl`.

## Exception: rtmpdump keeps OpenSSL

`rtmpdump` only offers OpenSSL / GnuTLS / PolarSSL backends — PolarSSL is
the *pre-3.x* mbedtls, incompatible with nixpkgs' mbedtls 3.x — so there is
no mbedtls path. The standalone `unpins/rtmpdump` therefore keeps
`CRYPTO=OPENSSL` (the working full-feature option for `rtmpe://` /
`rtmpte://`). ffmpeg does not use librtmp either: it drops
`--enable-librtmp` for its *native* rtmp/rtmpe/rtmps protocols, which
do crypto via the OpenSSL ffmpeg already links (`rtmpdh.c`
`CONFIG_OPENSSL`). librtmp would only add a dep and subtract working
crypto.
