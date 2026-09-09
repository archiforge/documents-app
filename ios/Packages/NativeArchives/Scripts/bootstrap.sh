#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PACKAGE_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
BUILD_ROOT=${NATIVE_ARCHIVES_BUILD_DIR:-"$PACKAGE_ROOT/.build"}
DOWNLOAD_ROOT="$BUILD_ROOT/downloads"
SOURCE_ROOT="$BUILD_ROOT/sources"
OUTPUT_ROOT="$BUILD_ROOT/output"
ARTIFACT_ROOT="$PACKAGE_ROOT/Artifacts"

LIBARCHIVE_VERSION=3.8.9
LIBARCHIVE_URL="https://www.libarchive.org/downloads/libarchive-${LIBARCHIVE_VERSION}.tar.xz"
LIBARCHIVE_SHA256=888c934f9d95648ecb9163dc8e23ab80a476ecb81a8f1154704a227b5b676dde

XZ_VERSION=5.8.3
XZ_URL="https://github.com/tukaani-project/xz/releases/download/v${XZ_VERSION}/xz-${XZ_VERSION}.tar.xz"
XZ_SHA256=fff1ffcf2b0da84d308a14de513a1aa23d4e9aa3464d17e64b9714bfdd0bbfb6

IOS_MINIMUM_VERSION=${IOS_MINIMUM_VERSION:-26.0}
# Libtool's static-archive rule is not safe to run in parallel on all Xcode
# toolchains. Keep the default deterministic; callers can opt into a higher
# value after validating their local toolchain.
JOBS=${JOBS:-1}

download_and_verify() {
    url=$1
    output=$2
    expected=$3

    if [ ! -f "$output" ]; then
        curl --fail --location --silent --show-error "$url" --output "$output"
    fi
    actual=$(shasum -a 256 "$output" | awk '{print $1}')
    if [ "$actual" != "$expected" ]; then
        echo "Checksum mismatch for $output" >&2
        echo "Expected: $expected" >&2
        echo "Actual:   $actual" >&2
        exit 1
    fi
}

extract_once() {
    archive=$1
    directory=$2
    if [ ! -d "$directory" ]; then
        mkdir -p "$SOURCE_ROOT"
        tar -xJf "$archive" -C "$SOURCE_ROOT"
    fi
}

sdk_path() {
    xcrun --sdk "$1" --show-sdk-path
}

sdk_clang() {
    xcrun --sdk "$1" --find clang
}

sdk_tool() {
    xcrun --sdk "$1" --find "$2"
}

target_flags() {
    sdk=$1
    target=$2
    arch=$3
    sdk_root=$(sdk_path "$sdk")
    if [ "$sdk" = "iphonesimulator" ]; then
        minimum_flag="-mios-simulator-version-min=$IOS_MINIMUM_VERSION"
    else
        minimum_flag="-miphoneos-version-min=$IOS_MINIMUM_VERSION"
    fi
    printf '%s' "-target $target -arch $arch -isysroot $sdk_root $minimum_flag -fPIC"
}

build_liblzma() {
    sdk=$1
    target=$2
    arch=$3
    name=$4
    source="$SOURCE_ROOT/xz-${XZ_VERSION}"
    build="$BUILD_ROOT/xz-$name"
    prefix="$OUTPUT_ROOT/xz-$name"
    rm -rf "$build" "$prefix"
    mkdir -p "$build" "$prefix"

    flags=$(target_flags "$sdk" "$target" "$arch")
    clang=$(sdk_clang "$sdk")
    ar=$(sdk_tool "$sdk" ar)
    ranlib=$(sdk_tool "$sdk" ranlib)

    (
        cd "$build"
        CC="$clang $flags" \
        CFLAGS="$flags" \
        CPPFLAGS="$flags" \
        AR="$ar" \
        RANLIB="$ranlib" \
        "$source/configure" \
            --host=aarch64-apple-darwin \
            --prefix="$prefix" \
            --enable-static \
            --disable-shared \
            --disable-doc \
            --disable-nls \
            --disable-xz \
            --disable-xzdec \
            --disable-lzmadec \
            --disable-lzmainfo
        make -j"$JOBS"
        make install
    )
}

build_libarchive() {
    sdk=$1
    target=$2
    arch=$3
    name=$4
    lzma_prefix=$5
    source="$SOURCE_ROOT/libarchive-${LIBARCHIVE_VERSION}"
    build="$BUILD_ROOT/libarchive-$name"
    prefix="$OUTPUT_ROOT/libarchive-$name"
    rm -rf "$build" "$prefix"
    mkdir -p "$build" "$prefix"

    flags=$(target_flags "$sdk" "$target" "$arch")
    clang=$(sdk_clang "$sdk")
    ar=$(sdk_tool "$sdk" ar)
    ranlib=$(sdk_tool "$sdk" ranlib)

    (
        cd "$build"
        CC="$clang $flags" \
        CFLAGS="$flags" \
        CPPFLAGS="$flags -I$lzma_prefix/include" \
        LDFLAGS="$flags -L$lzma_prefix/lib" \
        LIBS="$lzma_prefix/lib/liblzma.a" \
        AR="$ar" \
        RANLIB="$ranlib" \
        "$source/configure" \
            --host=aarch64-apple-darwin \
            --prefix="$prefix" \
            --enable-static \
            --disable-shared \
            --disable-bsdtar \
            --disable-bsdcpio \
            --disable-bsdcat \
            --disable-bsdunzip \
            --without-zlib \
            --without-bz2lib \
            --without-iconv \
            --without-expat \
            --without-xml2 \
            --without-lz4 \
            --without-zstd \
            --without-openssl \
            --without-nettle \
            --with-lzma="$lzma_prefix"
        make -j"$JOBS"
        make install
    )
}

build_slice() {
    sdk=$1
    target=$2
    arch=$3
    name=$4
    lzma_prefix="$OUTPUT_ROOT/xz-$name"
    archive_prefix="$OUTPUT_ROOT/libarchive-$name"
    slice="$OUTPUT_ROOT/slice-$name"
    wrapper_object="$slice/NativeArchivesC.o"
    library="$slice/libNativeArchivesC.a"

    rm -rf "$slice"
    mkdir -p "$slice"
    flags=$(target_flags "$sdk" "$target" "$arch")
    clang=$(sdk_clang "$sdk")
    libtool=$(sdk_tool "$sdk" libtool)

    "$clang" $flags \
        -I"$PACKAGE_ROOT/Sources/NativeArchivesC" \
        -I"$archive_prefix/include" \
        -c "$PACKAGE_ROOT/Sources/NativeArchivesC/NativeArchivesC.c" \
        -o "$wrapper_object"

    "$libtool" -static -o "$library" \
        "$wrapper_object" \
        "$archive_prefix/lib/libarchive.a" \
        "$lzma_prefix/lib/liblzma.a"
}

mkdir -p "$DOWNLOAD_ROOT" "$SOURCE_ROOT" "$OUTPUT_ROOT"
download_and_verify \
    "$LIBARCHIVE_URL" \
    "$DOWNLOAD_ROOT/libarchive-${LIBARCHIVE_VERSION}.tar.xz" \
    "$LIBARCHIVE_SHA256"
download_and_verify \
    "$XZ_URL" \
    "$DOWNLOAD_ROOT/xz-${XZ_VERSION}.tar.xz" \
    "$XZ_SHA256"

extract_once \
    "$DOWNLOAD_ROOT/libarchive-${LIBARCHIVE_VERSION}.tar.xz" \
    "$SOURCE_ROOT/libarchive-${LIBARCHIVE_VERSION}"
extract_once \
    "$DOWNLOAD_ROOT/xz-${XZ_VERSION}.tar.xz" \
    "$SOURCE_ROOT/xz-${XZ_VERSION}"

build_liblzma iphonesimulator arm64-apple-ios${IOS_MINIMUM_VERSION}-simulator arm64 simulator
build_liblzma iphoneos arm64-apple-ios${IOS_MINIMUM_VERSION} arm64 device
build_libarchive iphonesimulator arm64-apple-ios${IOS_MINIMUM_VERSION}-simulator arm64 simulator "$OUTPUT_ROOT/xz-simulator"
build_libarchive iphoneos arm64-apple-ios${IOS_MINIMUM_VERSION} arm64 device "$OUTPUT_ROOT/xz-device"
build_slice iphonesimulator arm64-apple-ios${IOS_MINIMUM_VERSION}-simulator arm64 simulator
build_slice iphoneos arm64-apple-ios${IOS_MINIMUM_VERSION} arm64 device

HEADER_ROOT="$BUILD_ROOT/NativeArchivesC-headers"
rm -rf "$HEADER_ROOT" "$ARTIFACT_ROOT/NativeArchivesC.xcframework"
mkdir -p "$HEADER_ROOT"
cp "$PACKAGE_ROOT/Sources/NativeArchivesC/NativeArchivesC.h" "$HEADER_ROOT/"
cat > "$HEADER_ROOT/module.modulemap" <<'EOF'
module NativeArchivesC {
    umbrella header "NativeArchivesC.h"
    export *
}
EOF

mkdir -p "$ARTIFACT_ROOT"
xcodebuild -create-xcframework \
    -library "$OUTPUT_ROOT/slice-device/libNativeArchivesC.a" \
    -headers "$HEADER_ROOT" \
    -library "$OUTPUT_ROOT/slice-simulator/libNativeArchivesC.a" \
    -headers "$HEADER_ROOT" \
    -output "$ARTIFACT_ROOT/NativeArchivesC.xcframework"

cp "$SOURCE_ROOT/libarchive-${LIBARCHIVE_VERSION}/COPYING" \
    "$ARTIFACT_ROOT/libarchive.COPYING"
cp "$SOURCE_ROOT/xz-${XZ_VERSION}/COPYING" \
    "$ARTIFACT_ROOT/xz.COPYING"
cp "$SOURCE_ROOT/xz-${XZ_VERSION}/COPYING.0BSD" \
    "$ARTIFACT_ROOT/xz.COPYING.0BSD"

echo "Built $ARTIFACT_ROOT/NativeArchivesC.xcframework"
