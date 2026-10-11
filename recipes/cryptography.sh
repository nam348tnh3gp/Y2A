#!/bin/bash
# p4a-style recipe: cryptography

RECIPE_P4A_VERSION="43.0.0"
RECIPE_P4A_DEPENDS="openssl rust"

recipe_env() {
    echo "  → [recipe/cryptography] set OPENSSL_DIR + provider flags"

    export OPENSSL_DIR="${DEPS_INSTALL}"
    export OPENSSL_LIB_DIR="${DEPS_INSTALL}/lib"
    export OPENSSL_INCLUDE_DIR="${DEPS_INSTALL}/include"

    # QUAN TRỌNG: giữ legacy provider → OSSL_PROVIDER_unload có mặt
    export CRYPTOGRAPHY_BUILD_OPENSSL_NO_LEGACY=0
    export OPENSSL_NO_MODULE=1

    export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="${NDK_CC}"
    export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS="\
-C link-arg=-L${TARGET_ROOT}/lib \
-C link-arg=-L${DEPS_INSTALL}/lib \
-C link-arg=-lssl \
-C link-arg=-lcrypto \
-C link-arg=-lpython${PYTHON_MINOR}"
}

recipe_setup_args() {
    return 0
}

recipe_patch() {
    local src="$1"
    if [ -f "$src/src/rust/build.rs" ]; then
        echo "    [recipe/cryptography] build.rs tồn tại — OK"
    fi
}