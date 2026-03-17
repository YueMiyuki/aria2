#!/usr/bin/env bash
set -euo pipefail

: "${TARGET_OS:?TARGET_OS is required}"
: "${TARGET_ARCH:?TARGET_ARCH is required}"
: "${OUTPUT_DIR:?OUTPUT_DIR is required}"

CONFIGURE_FLAGS=(
  --disable-nls
  --disable-bittorrent
  --disable-metalink
  --disable-websocket
  --without-libxml2
  --without-libexpat
  --without-libcares
  --without-sqlite3
  --without-libssh2
  --without-libz
  --without-libnettle
  --without-libgmp
  --without-libgcrypt
)

case "${TARGET_OS}" in
  win)
    CONFIGURE_FLAGS+=(
      --with-wintls
      --without-appletls
      --without-openssl
      --without-gnutls
    )
    ;;
  darwin)
    CONFIGURE_FLAGS+=(
      --with-appletls
      --without-wintls
      --without-openssl
      --without-gnutls
    )
    ;;
  linux)
    CONFIGURE_FLAGS+=(
      --with-openssl
      --without-gnutls
      --without-appletls
      --without-wintls
    )
    ;;
  *)
    echo "Unsupported TARGET_OS: ${TARGET_OS}" >&2
    exit 1
    ;;
esac

if [[ -n "${HOST_TRIPLE:-}" ]]; then
  CONFIGURE_FLAGS+=("--host=${HOST_TRIPLE}")
fi

if [[ -n "${PKG_CONFIG_LIBDIR_OVERRIDE:-}" ]]; then
  export PKG_CONFIG_LIBDIR="${PKG_CONFIG_LIBDIR_OVERRIDE}"
fi

jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
if [[ -z "${jobs}" ]]; then
  jobs="$(nproc 2>/dev/null || true)"
fi
if [[ -z "${jobs}" ]]; then
  jobs="$(sysctl -n hw.ncpu 2>/dev/null || true)"
fi
if [[ -z "${jobs}" ]]; then
  jobs=2
fi

if [[ "${TARGET_OS}" == "linux" && -n "${HOST_TRIPLE:-}" ]]; then
  openssl_version="${OPENSSL_VERSION:-3.3.3}"
  openssl_prefix="${PWD}/.openssl-${TARGET_ARCH}"
  openssl_tar="openssl-${openssl_version}.tar.gz"
  openssl_src="openssl-${openssl_version}"

  case "${TARGET_ARCH}" in
    arm64)
      openssl_target="linux-aarch64"
      ;;
    armv7l)
      openssl_target="linux-armv4"
      ;;
    *)
      echo "Unsupported linux cross SSL target: ${TARGET_ARCH}" >&2
      exit 1
      ;;
  esac

  if [[ ! -d "${openssl_prefix}" ]]; then
    curl -fsSL "https://www.openssl.org/source/${openssl_tar}" -o "${openssl_tar}"
    tar xf "${openssl_tar}"
    pushd "${openssl_src}" >/dev/null
    env -u CC -u CXX ./Configure "${openssl_target}" \
      --cross-compile-prefix="${HOST_TRIPLE}-" \
      no-shared no-tests no-module no-dso --prefix="${openssl_prefix}"
    make -j"${jobs}"
    make install_sw
    popd >/dev/null
  fi

  export PKG_CONFIG_PATH="${openssl_prefix}/lib/pkgconfig:${openssl_prefix}/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
fi

autoreconf -i
./configure "${CONFIGURE_FLAGS[@]}" | tee configure.out

if ! grep -q "SSL Support:    yes" configure.out; then
  echo "SSL support is not enabled for ${TARGET_OS}-${TARGET_ARCH}" >&2
  exit 1
fi

case "${TARGET_OS}" in
  linux)
    grep -q "OpenSSL:        yes" configure.out || {
      echo "Expected OpenSSL backend for linux build" >&2
      exit 1
    }
    ;;
  darwin)
    grep -q "AppleTLS:       yes" configure.out || {
      echo "Expected AppleTLS backend for darwin build" >&2
      exit 1
    }
    ;;
  win)
    grep -q "WinTLS:         yes" configure.out || {
      echo "Expected WinTLS backend for win build" >&2
      exit 1
    }
    ;;
esac

make -j"${jobs}"

mkdir -p "${OUTPUT_DIR}"

if [[ "${TARGET_OS}" == "win" ]]; then
  if [[ -f "src/aria2c.exe" ]]; then
    src_binary="src/aria2c.exe"
  elif [[ -f "src/.libs/aria2c.exe" ]]; then
    src_binary="src/.libs/aria2c.exe"
  else
    echo "aria2c.exe not found after build" >&2
    ls -la src src/.libs 2>/dev/null || true
    exit 1
  fi
  output_binary="${OUTPUT_DIR}/win-${TARGET_ARCH}.exe"
else
  if [[ -f "src/.libs/aria2c" ]]; then
    src_binary="src/.libs/aria2c"
  elif [[ -f "src/aria2c" ]]; then
    src_binary="src/aria2c"
  else
    echo "aria2c not found after build" >&2
    ls -la src src/.libs 2>/dev/null || true
    exit 1
  fi
  output_binary="${OUTPUT_DIR}/${TARGET_OS}-${TARGET_ARCH}"
fi

cp "${src_binary}" "${output_binary}"

strip_bin="${STRIP_BIN:-strip}"
if command -v "${strip_bin}" >/dev/null 2>&1; then
  "${strip_bin}" "${output_binary}" || true
fi

if [[ "${TARGET_OS}" == "win" && "${TARGET_ARCH}" == "x64" && "${WIN_ARM64_ALIAS:-false}" == "true" ]]; then
  cp "${output_binary}" "${OUTPUT_DIR}/win-arm64.exe"
fi

ls -lh "${OUTPUT_DIR}"
