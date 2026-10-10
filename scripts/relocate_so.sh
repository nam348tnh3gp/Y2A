#!/usr/bin/env bash
# ============================================================
# relocate_so.sh — đệ quy đổi tên + sửa đường dẫn mọi file .so
#
# Việc làm (cho TẤT CẢ ELF dưới các thư mục truyền vào):
#   1. Bỏ hậu tố phiên bản:  libavcodec.so.62.11.100 -> libavcodec.so
#      (Android chỉ đóng gói lib*.so; symlink bị mất khi copy)
#   2. Gom cả symlink (libavcodec.so.62 -> ...62.11.100) vào bảng map
#      để NEEDED "libavcodec.so.62" cũng được đổi đúng
#   3. patchelf: --set-soname, --replace-needed cho mọi file
#   4. Ghi lại RPATH/RUNPATH (mặc định '$ORIGIN'), bỏ đường dẫn Termux
#   5. Báo NEEDED không còn trỏ tới đâu (ngoài lib hệ thống Android)
#
# Dùng:
#   scripts/relocate_so.sh [-r RPATH] [-s] DIR [DIR...]
#     -r RPATH   rpath mới (mặc định: $ORIGIN)
#     -s         strict: exit 1 nếu còn NEEDED thiếu
#   Biến môi trường: PATCHELF=patchelf  READELF=readelf
# ============================================================
set -euo pipefail

PATCHELF="${PATCHELF:-patchelf}"
READELF="${READELF:-readelf}"
NEW_RPATH='$ORIGIN'
STRICT=0

while getopts "r:s" opt; do
  case "$opt" in
    r) NEW_RPATH="$OPTARG" ;;
    s) STRICT=1 ;;
    *) echo "usage: $0 [-r RPATH] [-s] DIR..." >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
[ "$#" -ge 1 ] || { echo "thiếu DIR" >&2; exit 2; }

# Lib do Android cung cấp — không bundle, không cảnh báo thiếu
SYSTEM_LIBS_RE='^(libc|libm|libdl|liblog|libandroid|libz|libEGL|libGLESv[123]|libvulkan|libOpenSLES|libmediandk|libnativewindow|libjnigraphics|libstdc\+\+|ld-android|linker64)\.so$'

# "libfoo.so.1.2.3" -> "libfoo.so"
strip_ver() { echo "$1" | sed -E 's/(\.so)(\.[0-9]+)+$/\1/'; }

is_elf() { [ "$(head -c4 "$1" 2>/dev/null | od -An -c | tr -d ' ')" = '177ELF' ]; }

declare -A MAP=()   # tên cũ -> tên mới (mọi alias, kể cả symlink)

# ---------- PASS 1: đổi tên file thật + dựng bảng map ----------
for dir in "$@"; do
  [ -d "$dir" ] || { echo "bỏ qua (không phải thư mục): $dir"; continue; }

  # 1a. Symlink trước: ghi alias -> tên mới của target rồi xoá symlink
  while IFS= read -r -d '' link; do
    base=$(basename "$link")
    tgt=$(basename "$(readlink -f "$link")")
    MAP["$base"]="$(strip_ver "$tgt")"
    rm -f "$link"
  done < <(find "$dir" -type l \( -name '*.so' -o -name '*.so.*' \) -print0)

  # 1b. File thật: bỏ hậu tố phiên bản
  while IFS= read -r -d '' f; do
    is_elf "$f" || continue
    base=$(basename "$f")
    new=$(strip_ver "$base")
    MAP["$base"]="$new"
    MAP["$new"]="$new"
    if [ "$new" != "$base" ]; then
      dest="$(dirname "$f")/$new"
      # nếu đã có file cùng tên mới: giữ file lớn hơn (thường là bản đầy đủ)
      if [ -e "$dest" ] && [ "$(stat -c%s "$dest")" -ge "$(stat -c%s "$f")" ]; then
        rm -f "$f"
      else
        mv -f "$f" "$dest"
      fi
      echo "rename: $base -> $new"
    fi
  done < <(find "$dir" -type f \( -name '*.so' -o -name '*.so.*' \) -print0)
done

# ---------- PASS 2: vá SONAME / NEEDED / RPATH cho mọi ELF ----------
declare -A HAVE=()
for dir in "$@"; do
  while IFS= read -r -d '' f; do HAVE["$(basename "$f")"]=1
  done < <(find "$dir" -type f -name '*.so' -print0)
done

PATCHED=0; MISSING=0
declare -A MISSING_SEEN=()

for dir in "$@"; do
  # *.so + binary không đuôi (ffmpeg, ffprobe...) -> kiểm tra bằng magic ELF
  while IFS= read -r -d '' f; do
    is_elf "$f" || continue
    name=$(basename "$f")

    # SONAME
    cur_soname=$("$READELF" -d "$f" 2>/dev/null | sed -n 's/.*Library soname: \[\(.*\)\]/\1/p')
    if [ -n "$cur_soname" ]; then
      new_soname=$(strip_ver "$cur_soname")
      if [ "$new_soname" != "$cur_soname" ]; then
        "$PATCHELF" --set-soname "$new_soname" "$f"; PATCHED=$((PATCHED+1))
      fi
    fi

    # NEEDED
    while IFS= read -r needed; do
      [ -n "$needed" ] || continue
      new_needed="${MAP[$needed]:-$(strip_ver "$needed")}"
      if [ "$new_needed" != "$needed" ]; then
        "$PATCHELF" --replace-needed "$needed" "$new_needed" "$f"; PATCHED=$((PATCHED+1))
      fi
      if [[ ! "$new_needed" =~ $SYSTEM_LIBS_RE ]] && [ -z "${HAVE[$new_needed]:-}" ]; then
        key="$new_needed"
        if [ -z "${MISSING_SEEN[$key]:-}" ]; then
          echo "⚠ thiếu lib: $new_needed (cần bởi $name)"
          MISSING_SEEN[$key]=1; MISSING=$((MISSING+1))
        fi
      fi
    done < <("$READELF" -d "$f" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p')

    # RPATH/RUNPATH (xoá /data/data/com.termux/... rồi đặt mới)
    old_rp=$("$READELF" -d "$f" 2>/dev/null | sed -n 's/.*\(RPATH\|RUNPATH\).*\[\(.*\)\]/\2/p' | head -1)
    if [ -n "$old_rp" ] || [[ "$name" == *.so ]]; then
      "$PATCHELF" --remove-rpath "$f" 2>/dev/null || true
      "$PATCHELF" --force-rpath --set-rpath "$NEW_RPATH" "$f"
      PATCHED=$((PATCHED+1))
      [ -n "$old_rp" ] && echo "rpath: $name  [$old_rp] -> [$NEW_RPATH]"
    fi
  done < <(find "$dir" -type f -print0)
done

echo "Hoàn tất: $PATCHED chỉnh sửa, $MISSING lib thiếu"
if [ "$STRICT" -eq 1 ] && [ "$MISSING" -gt 0 ]; then
  echo "❌ strict: còn $MISSING NEEDED không có trong thư mục" >&2
  exit 1
fi