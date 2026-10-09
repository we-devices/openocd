#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Sergiu Popov <sg.popov@pm.me>
# Native portable builds used by .github/workflows/binaries.yml.
set -euo pipefail

platform=${1:?Usage: build-binaries.sh linux-x86_64|windows-x86_64|macos-x86_64|macos-arm64}
case "$platform" in
    linux-x86_64|windows-x86_64|macos-x86_64|macos-arm64) ;;
    *) echo "Unsupported platform: $platform" >&2; exit 1 ;;
esac

src=$(cd "$(dirname "$0")/.." && pwd)
work="$src/.binary-build/$platform"
deps="$work/deps"
jobs=${MAKE_JOBS:-4}
revision=$(git -C "$src" rev-parse --short=12 HEAD)
name="openocd-$revision-$platform"
package="$work/stage/$name"
mkdir -p "$work" "$deps" "$src/dist"

# Restrict detection to our static dependencies, not runner-installed libraries.
export PKG_CONFIG_LIBDIR="$deps/lib/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
export CFLAGS="${CFLAGS:--O2}"
export LDFLAGS="${LDFLAGS:-}"
host_args=()
if [[ "$platform" == windows-* ]]; then
    host_args=(--host=x86_64-w64-mingw32)
    export LDFLAGS="$LDFLAGS -static -static-libgcc"
elif [[ "$platform" == macos-* ]]; then
    export MACOSX_DEPLOYMENT_TARGET=13.0
fi

cd "$work"
curl --fail --location --retry 3 -o libusb.tar.bz2 \
    https://github.com/libusb/libusb/releases/download/v1.0.29/libusb-1.0.29.tar.bz2
tar -xjf libusb.tar.bz2
(
    cd libusb-1.0.29
    ./configure "${host_args[@]}" --prefix="$deps" --enable-static --disable-shared --disable-udev
    make -j"$jobs"
    make install
)

curl --fail --location --retry 3 -o hidapi.tar.gz \
    https://github.com/libusb/hidapi/archive/refs/tags/hidapi-0.15.0.tar.gz
tar -xzf hidapi.tar.gz
cmake -S hidapi-hidapi-0.15.0 -B hidapi-build -G Ninja \
    -DCMAKE_INSTALL_PREFIX="$deps" -DCMAKE_INSTALL_LIBDIR=lib \
    -DBUILD_SHARED_LIBS=OFF -DHIDAPI_WITH_HIDRAW=OFF \
    -DHIDAPI_WITH_LIBUSB=ON -DHIDAPI_BUILD_HIDTEST=OFF
cmake --build hidapi-build --parallel "$jobs"
cmake --install hidapi-build

# Preserve private link flags (pthread, Windows libraries, macOS frameworks).
LIBUSB1_LIBS=$(pkg-config --static --libs libusb-1.0)
export LIBUSB1_LIBS
hidapi=hidapi
if [[ "$platform" == linux-* ]]; then hidapi='hidapi-libusb'; fi
HIDAPI_LIBS=$(pkg-config --static --libs "$hidapi")
export HIDAPI_LIBS
# HIDAPI 0.15.0's .pc files omit the static backend's system dependencies.
case "$platform" in
    linux-*) export HIDAPI_LIBS="$HIDAPI_LIBS $LIBUSB1_LIBS -pthread" ;;
    macos-*) export HIDAPI_LIBS="$HIDAPI_LIBS -framework IOKit -framework CoreFoundation -pthread" ;;
esac

cd "$src"
./bootstrap
mkdir -p "$work/openocd"
cd "$work/openocd"
"$src/configure" "${host_args[@]}" --prefix=/ --bindir=/bin --datarootdir=/share \
    --enable-internal-jimtcl --disable-internal-libjaylink \
    --enable-cmsis-dap --enable-cmsis-dap-v2 --enable-cmsis-dap-tcp \
    --without-capstone --disable-werror
make -j"$jobs"
make install DESTDIR="$package"
mkdir -p "$package/share/licenses"
cp "$src/COPYING" "$package/share/licenses/openocd.txt"
cp "$work/libusb-1.0.29/COPYING" "$package/share/licenses/libusb.txt"
cp "$work/hidapi-hidapi-0.15.0/LICENSE"* "$package/share/licenses/"
cp "$src/jimtcl/LICENSE" "$package/share/licenses/jimtcl.txt"
cp "$src/README.binaries.md" "$package/README.md"
mkdir -p "$package/share/openocd/contrib"
cp "$src/contrib/60-openocd.rules" "$package/share/openocd/contrib/"
{
    echo "OpenOCD source: https://github.com/we-devices/openocd"
    echo "Commit: $(git -C "$src" rev-parse HEAD)"
    echo "Platform: $platform"
    echo "libusb: 1.0.29; hidapi: 0.15.0"
    echo "jimtcl: $(git -C "$src/jimtcl" rev-parse HEAD)"
    "$package/bin/openocd" --version 2>&1
} > "$package/BUILD.txt"

# Test after relocation, outside the checkout, with no -s override. No probe needed.
mkdir -p "$work/smoke"
cd "$work/smoke"
"$package/bin/openocd" \
    -f interface/cmsis-dap-tcp.cfg \
    -c 'cmsis-dap tcp host 127.0.0.1' \
    -c 'cmsis-dap tcp port 4441' \
    -c 'cmsis-dap tcp min_timeout 150' \
    -c 'transport select swd' \
    -c shutdown

# Reject accidental dependencies on the build environment.
case "$platform" in
    linux-*)
        ldd "$package/bin/openocd" | tee "$work/runtime-libraries.txt"
        if grep -Ei 'not found|libusb|libhidapi|libjim|libcapstone' "$work/runtime-libraries.txt"; then
            echo 'Unexpected runtime dependency' >&2; exit 1
        fi
        ;;
    macos-*)
        otool -L "$package/bin/openocd" | tee "$work/runtime-libraries.txt"
        if tail -n +2 "$work/runtime-libraries.txt" | grep -Ev '^[[:space:]]+(/usr/lib/|/System/Library/)'; then
            echo 'Non-system runtime dependency' >&2; exit 1
        fi
        ;;
    windows-*)
        objdump -p "$package/bin/openocd.exe" | tee "$work/runtime-libraries.txt"
        if grep 'DLL Name:' "$work/runtime-libraries.txt" | grep -Ei 'lib.*\.dll|msys.*\.dll'; then
            echo 'Non-system runtime dependency' >&2; exit 1
        fi
        ;;
esac

cd "$work/stage"
if [[ "$platform" == windows-* ]]; then
    archive="$src/dist/$name.zip"
    zip -qr "$archive" "$name"
else
    archive="$src/dist/$name.tar.gz"
    tar -czf "$archive" "$name"
fi
cd "$src/dist"
if command -v sha256sum >/dev/null; then
    sha256sum "$(basename "$archive")" > "$(basename "$archive").sha256"
else
    shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256"
fi
