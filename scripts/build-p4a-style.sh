# ============================================================
# 5.5. PYO3 CONFIG — ép Rust link tường minh tới libpython
#      Đây là cách ly của p4a: extension phải NEEDED libpython
#      ngay từ build, không phụ thuộc loader lookup.
# ============================================================
PYO3_CONFIG="$TMP_BUILD/pyo3-config.txt"
cat > "$PYO3_CONFIG" <<EOF
implementation=CPython
version=$PY_MINOR
shared=true
abi3=true
lib_name=python$PY_MINOR
lib_dir=$TARGET_ROOT/lib
executable=$TARGET_ROOT/bin/python$PY_MINOR
pointer_width=64
build_flags=
suppress_build_script_link_lines=false
EOF

export PYO3_CONFIG_FILE="$PYO3_CONFIG"
echo "  PYO3_CONFIG_FILE: $PYO3_CONFIG"
echo "  PYO3 lib_dir:     $TARGET_ROOT/lib"