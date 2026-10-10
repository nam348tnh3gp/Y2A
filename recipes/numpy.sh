#!/bin/bash
# p4a-style recipe: numpy
# Adapted from python-for-android NumpyRecipe:
#   version = "v2.3.0"
#   opt_depends = ["libopenblas"]
#   min_ndk_api_support = 24
#   extra_build_args = [-Csetup-args=-Dblas=... ]

RECIPE_P4A_VERSION="2.3.0"
RECIPE_P4A_MIN_NDK_API=24
RECIPE_P4A_OPT_DEPENDS="libopenblas"

recipe_env() {
    export NPY_DISABLE_SVML=1
    export NPY_USE_BLAS_ILP64=0
    export NPY_BLAS_LIBS="-lopenblas"
    export NPY_CBLAS_LIBS="-lopenblas"
    export NPY_LAPACK_LIBS="-lopenblas"

    export _PYTHON_HOST_PLATFORM="${ANDROID_TAG}"
    export TARGET_PYTHON_EXE="${TARGET_ROOT}/bin/python${PYTHON_MINOR}"
}

recipe_setup_args() {
    cat <<'EOF'
-Csetup-args=-Dblas=openblas
-Csetup-args=-Dlapack=openblas
-Csetup-args=-Dallow-noblas=false
-Csetup-args=-Dbuildtype=plain
EOF
}

recipe_patch() {
    local src="$1"
    find "$src" -name 'meson.build' -type f -print0 2>/dev/null | \
        xargs -0 -r sed -i \
            "s/longdouble_format\s*[:=]\s*'[^']*'/longdouble_format: 'IEEE_QUAD_LE'/g" \
            2>/dev/null || true
}