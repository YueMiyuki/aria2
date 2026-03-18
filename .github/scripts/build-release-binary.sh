#!/usr/bin/env bash
set -euo pipefail

: "${TARGET_OS:?TARGET_OS is required}"
: "${TARGET_ARCH:?TARGET_ARCH is required}"
: "${OUTPUT_DIR:?OUTPUT_DIR is required}"

CONFIGURE_FLAGS=(
  --disable-nls
  --enable-bittorrent
  --disable-metalink
  --enable-websocket
  --without-libcares
  --with-sqlite3
  --with-libssh2
  --without-libxml2
  --without-libexpat
  --without-libz
)

case "${TARGET_OS}" in
  linux|darwin|win)
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

if [[ "${TARGET_OS}" == "darwin" ]]; then
  export LDFLAGS="${LDFLAGS:-} -framework Security -framework CoreFoundation"
fi

if [[ "${TARGET_OS}" == "win" ]]; then
  # Static OpenSSL/libssh2 on MinGW needs explicit Windows system libs.
  win_system_libs="-lws2_32 -lcrypt32 -lbcrypt -liphlpapi"
  export LIBS="${LIBS:-} ${win_system_libs}"
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

if [[ -n "${HOST_TRIPLE:-}" ]]; then
  dep_prefix="${PWD}/.crossdeps-${TARGET_OS}-${TARGET_ARCH}"
  dep_build="${PWD}/.crossdeps-build-${TARGET_OS}-${TARGET_ARCH}"
  mkdir -p "${dep_prefix}" "${dep_build}"

  build_machine="$(gcc -dumpmachine 2>/dev/null || echo x86_64-linux-gnu)"

  fetch_extract() {
    local url="$1"
    local tarball="$2"
    local src_dir="$3"

    pushd "${dep_build}" >/dev/null
    if [[ ! -f "${tarball}" ]]; then
      curl -fsSL "${url}" -o "${tarball}"
    fi
    rm -rf "${src_dir}"
    tar xf "${tarball}"
    popd >/dev/null
  }

  build_zlib() {
    local version="1.3.1"
    local src="zlib-${version}"
    if [[ -f "${dep_prefix}/lib/libz.a" ]]; then
      return
    fi
    fetch_extract "https://github.com/madler/zlib/releases/download/v${version}/${src}.tar.gz" "${src}.tar.gz" "${src}"
    pushd "${dep_build}/${src}" >/dev/null
    CC="${HOST_TRIPLE}-gcc" AR="${HOST_TRIPLE}-ar" RANLIB="${HOST_TRIPLE}-ranlib" \
      ./configure --prefix="${dep_prefix}" --static
    make -j"${jobs}"
    make install
    popd >/dev/null
  }

  build_expat() {
    local version="2.7.3"
    local src="expat-${version}"
    if [[ -f "${dep_prefix}/lib/libexpat.a" ]]; then
      return
    fi
    fetch_extract "https://github.com/libexpat/libexpat/releases/download/R_$(echo "${version}" | tr . _)/${src}.tar.xz" "${src}.tar.xz" "${src}"
    pushd "${dep_build}/${src}" >/dev/null
    ./configure --host="${HOST_TRIPLE}" --build="${build_machine}" \
      --disable-shared --enable-static --prefix="${dep_prefix}"
    make -j"${jobs}"
    make install
    popd >/dev/null
  }

  build_sqlite() {
    local version="3500400"
    local src="sqlite-autoconf-${version}"
    if [[ -f "${dep_prefix}/lib/libsqlite3.a" ]]; then
      return
    fi
    fetch_extract "https://www.sqlite.org/2025/${src}.tar.gz" "${src}.tar.gz" "${src}"
    pushd "${dep_build}/${src}" >/dev/null
    ./configure --host="${HOST_TRIPLE}" --build="${build_machine}" \
      --disable-shared --enable-static --prefix="${dep_prefix}"
    make -j"${jobs}"
    make install
    popd >/dev/null
  }

  build_openssl() {
    local version="3.3.3"
    local src="openssl-${version}"
    if [[ -f "${dep_prefix}/lib/libssl.a" ]]; then
      return
    fi

    local openssl_target=""
    case "${TARGET_OS}-${TARGET_ARCH}" in
      linux-arm64) openssl_target="linux-aarch64" ;;
      linux-armv7l) openssl_target="linux-armv4" ;;
      win-ia32) openssl_target="mingw" ;;
      win-x64) openssl_target="mingw64" ;;
      *)
        echo "Unsupported OpenSSL cross target: ${TARGET_OS}-${TARGET_ARCH}" >&2
        exit 1
        ;;
    esac

    fetch_extract "https://www.openssl.org/source/${src}.tar.gz" "${src}.tar.gz" "${src}"
    pushd "${dep_build}/${src}" >/dev/null
    env -u CC -u CXX ./Configure "${openssl_target}" \
      --cross-compile-prefix="${HOST_TRIPLE}-" \
      no-shared no-tests no-module no-dso --prefix="${dep_prefix}"
    make -j"${jobs}"
    make install_sw
    popd >/dev/null
  }

  build_libssh2() {
    local version="1.11.1"
    local src="libssh2-${version}"
    local libssh2_lib=""
    if [[ -f "${dep_prefix}/lib/libssh2.a" ]]; then
      libssh2_lib="${dep_prefix}/lib/libssh2.a"
    elif [[ -f "${dep_prefix}/lib64/libssh2.a" ]]; then
      libssh2_lib="${dep_prefix}/lib64/libssh2.a"
    fi

    if [[ -n "${libssh2_lib}" && \
      -f "${dep_prefix}/include/libssh2.h" && \
      -f "${dep_prefix}/include/libssh2_sftp.h" && \
      -f "${dep_prefix}/lib/pkgconfig/libssh2.pc" ]]; then
      return
    fi
    fetch_extract "https://www.libssh2.org/download/${src}.tar.gz" "${src}.tar.gz" "${src}"
    pushd "${dep_build}/${src}" >/dev/null
    local extra_libs=""
    if [[ "${TARGET_OS}" == "win" ]]; then
      extra_libs="-lws2_32 -lcrypt32"
    fi
    PKG_CONFIG_PATH="${dep_prefix}/lib/pkgconfig:${dep_prefix}/lib64/pkgconfig" \
    CPPFLAGS="-I${dep_prefix}/include" LDFLAGS="-L${dep_prefix}/lib -L${dep_prefix}/lib64" \
      ./configure --host="${HOST_TRIPLE}" --build="${build_machine}" \
      --disable-shared --enable-static --disable-examples-build \
      --with-openssl --with-libz --prefix="${dep_prefix}" LIBS="${extra_libs}"
    make -C src -j"${jobs}"
    make -C src install

    mkdir -p "${dep_prefix}/include" "${dep_prefix}/lib/pkgconfig"
    if compgen -G "include/libssh2*.h" >/dev/null; then
      cp include/libssh2*.h "${dep_prefix}/include/"
    fi

    local libdir="${dep_prefix}/lib"
    if [[ -f "${dep_prefix}/lib64/libssh2.a" ]]; then
      libdir="${dep_prefix}/lib64"
    fi

    cat > "${dep_prefix}/lib/pkgconfig/libssh2.pc" <<PC
prefix=${dep_prefix}
exec_prefix=\${prefix}
libdir=${libdir}
includedir=\${prefix}/include

Name: libssh2
Description: libssh2 library
Version: ${version}
Libs: -L\${libdir} -lssh2
Libs.private: -lz -lssl -lcrypto ${extra_libs}
Cflags: -I\${includedir}
PC
    popd >/dev/null
  }

  build_zlib
  build_expat
  build_sqlite
  build_openssl
  build_libssh2

  export CPPFLAGS="-I${dep_prefix}/include ${CPPFLAGS:-}"
  export LDFLAGS="-L${dep_prefix}/lib -L${dep_prefix}/lib64 ${LDFLAGS:-}"
  export PKG_CONFIG_PATH="${dep_prefix}/lib/pkgconfig:${dep_prefix}/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
fi

autoreconf -i
./configure "${CONFIGURE_FLAGS[@]}" | tee configure.out

if ! grep -q "SSL Support:    yes" configure.out; then
  echo "SSL support is not enabled for ${TARGET_OS}-${TARGET_ARCH}" >&2
  exit 1
fi

grep -q "OpenSSL:        yes" configure.out || {
  echo "Expected OpenSSL backend for ${TARGET_OS}-${TARGET_ARCH}" >&2
  exit 1
}

for feat in Bittorrent WebSocket; do
  if ! grep -Eq "^${feat}:[[:space:]]+yes" configure.out; then
    echo "Expected feature '${feat}' to be enabled for ${TARGET_OS}-${TARGET_ARCH}" >&2
    exit 1
  fi
done

if grep -Eq "^Metalink:[[:space:]]+yes" configure.out; then
  echo "Metalink must be disabled for ${TARGET_OS}-${TARGET_ARCH}" >&2
  exit 1
fi

for dep in "Libssh2" "SQLite3"; do
  if ! grep -Eq "^${dep}:[[:space:]]+yes" configure.out; then
    echo "Expected dependency feature '${dep}' to be enabled for ${TARGET_OS}-${TARGET_ARCH}" >&2
    exit 1
  fi
done

if grep -Eq "^LibCares:[[:space:]]+yes" configure.out; then
  echo "LibCares must be disabled for ${TARGET_OS}-${TARGET_ARCH}" >&2
  exit 1
fi

if grep -Eq "^Zlib:[[:space:]]+yes" configure.out; then
  echo "Zlib must be disabled for ${TARGET_OS}-${TARGET_ARCH}" >&2
  exit 1
fi

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
