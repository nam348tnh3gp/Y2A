#!/bin/bash
# p4a-style recipe: uvloop
# Adapted from python-for-android UvloopRecipe:
#   version = 'v0.19.0'
#   depends = ['librt', 'libpthread']
#   env["LIBUV_CONFIGURE_HOST"] = arch.command_prefix
#   env["PLATFORM"] = "android"

RECIPE_P4A_VERSION="0.19.0"
RECIPE_P4A_DEPENDS="librt libpthread"

recipe_env() {
    export LIBUV_CONFIGURE_HOST="${TARGET_HOST}"
    export PLATFORM="android"

    export ac_cv_host="${TARGET_HOST}"
    export ac_cv_build="x86_64-pc-linux-gnu"
    export ac_cv_target="${TARGET_HOST}"
    export cross_compiling="yes"

    export HOSTCC="/usr/bin/gcc"
    export HOSTCXX="/usr/bin/g++"
    export CC_FOR_BUILD="/usr/bin/gcc"
    export CXX_FOR_BUILD="/usr/bin/g++"
    export AR_FOR_BUILD="/usr/bin/ar"
    export RANLIB_FOR_BUILD="/usr/bin/ranlib"
}

recipe_patch() {
    local src="$1"
    local setup="$src/setup.py"
    [ -f "$setup" ] || return 0
    cp -n "$setup" "${setup}.bak" 2>/dev/null || true

    SETUP_PY="$setup" TARGET_HOST="${TARGET_HOST}" "${HOST_PYTHON}" - <<'PYEOF'
import os
p = os.environ["SETUP_PY"]
host = os.environ.get("TARGET_HOST", "aarch64-linux-android")
src = open(p).read()
orig = src

repl_single = (
    "['./configure', '--host=" + host + "', "
    "'--build=x86_64-pc-linux-gnu', "
    "'--disable-shared', '--enable-static']"
)
repl_double = repl_single.replace("'", '"')

src = src.replace("['./configure']", repl_single)
src = src.replace('[\"./configure\"]', repl_double)

if src != orig:
    open(p, "w").write(src)
    print(f"[recipe/uvloop] patched: {p}")
else:
    print(f"[recipe/uvloop] no change: {p}")
PYEOF
}
