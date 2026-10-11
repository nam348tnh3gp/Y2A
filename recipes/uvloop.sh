#!/bin/bash
# p4a-style recipe: uvloop
# Adapted from python-for-android UvloopRecipe
# uvloop >= 0.19 dùng scikit-build-core + libuv submodule build bằng make

RECIPE_P4A_VERSION="0.19.0"
RECIPE_P4A_DEPENDS="librt libpthread"

recipe_env() {
    export LIBUV_CONFIGURE_HOST="${TARGET_HOST}"
    export PLATFORM="android"

    export CFLAGS_UV="${CFLAGS:-} -fPIC -D__ANDROID_API__=${ANDROID_API} -D_GNU_SOURCE"
    export LDFLAGS_UV="${LDFLAGS:-}"

    # Đảm bảo make dùng NDK toolchain
    export CC="${NDK_CC}"
    export CXX="${NDK_CXX}"
    export AR="${NDK_AR}"
    export RANLIB="${RANLIB}"
    export STRIP="${STRIP}"
}

recipe_patch() {
    local src="$1"
    echo "  [recipe/uvloop] patch libuv build cho Android"

    # ── 1. Tìm thư mục libuv vendored ──
    local uv_dir=""
    for candidate in \
        "$src/vendor/libuv" \
        "$src/libuv" \
        "$src/uvloop/libuv"; do
        [ -d "$candidate" ] && uv_dir="$candidate" && break
    done

    if [ -z "$uv_dir" ]; then
        echo "  ⚠️  [recipe/uvloop] không tìm thấy libuv dir — bỏ qua patch"
        return 0
    fi
    echo "  [recipe/uvloop] libuv dir: $uv_dir"

    # ── 2. Patch setup.py: chèn env CC/AR/CFLAGS vào mọi subprocess gọi make ──
    local setup="$src/setup.py"
    if [ -f "$setup" ]; then
        cp -n "$setup" "${setup}.bak" 2>/dev/null || true

        SETUP_PY="$setup" \
        NDK_CC="${NDK_CC}" \
        NDK_AR="${NDK_AR}" \
        ANDROID_API="${ANDROID_API}" \
        "${HOST_PYTHON}" - <<'PYEOF'
import os, re
p = os.environ["SETUP_PY"]
cc = os.environ["NDK_CC"]
ar = os.environ["NDK_AR"]
api = os.environ["ANDROID_API"]
src = open(p).read()
orig = src

# Inject env CC/AR/CFLAGS vào mọi subprocess.check_call / subprocess.run gọi make
repl_patterns = [
    (r"subprocess\.check_call\(\s*\[\s*['\"]make['\"]",
     'subprocess.check_call(["env",'
     f'"CC={cc}",'
     f'"AR={ar}",'
     f'"CFLAGS=-fPIC -D__ANDROID_API__={api} -D_GNU_SOURCE",'
     '"make"'),
    (r"subprocess\.run\(\s*\[\s*['\"]make['\"]",
     'subprocess.run(["env",'
     f'"CC={cc}",'
     f'"AR={ar}",'
     f'"CFLAGS=-fPIC -D__ANDROID_API__={api} -D_GNU_SOURCE",'
     '"make"'),
]

for pat, repl in repl_patterns:
    new = re.sub(pat, repl, src)
    if new != src:
        src = new
        print(f"[recipe/uvloop] replaced: {pat[:50]}...")

if src == orig:
    print("[recipe/uvloop] không match pattern — prepend env override")
    src = (
        "import os as _os\n"
        f"_os.environ.setdefault('CC', '{cc}')\n"
        f"_os.environ.setdefault('CFLAGS', '-fPIC -D__ANDROID_API__={api} -D_GNU_SOURCE')\n"
        f"_os.environ.setdefault('AR', '{ar}')\n"
        f"_os.environ['PLATFORM'] = 'android'\n"
        f"_os.environ['LIBUV_CONFIGURE_HOST'] = 'aarch64-linux-android'\n"
        + src
    )

if src != orig:
    open(p, "w").write(src)
    print(f"[recipe/uvloop] patched: {p}")
else:
    print(f"[recipe/uvloop] no change: {p}")
PYEOF
    fi

    # ── 3. Fallback autotools (uvloop cũ) ──
    if [ -f "$setup" ] && grep -q '"./configure"' "$setup" 2>/dev/null; then
        SETUP_PY="$setup" TARGET_HOST="${TARGET_HOST}" \
        "${HOST_PYTHON}" - <<'PYEOF' 2>/dev/null || true
import os
p = os.environ.get("SETUP_PY", "")
if not p or not os.path.exists(p):
    raise SystemExit(0)
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
    print(f"[recipe/uvloop] patched autotools: {p}")
PYEOF
    fi
}