#!/usr/bin/env python3
"""
Sinh pip index (PEP 503) từ danh sách file .whl trong thư mục.
Hỗ trợ nhiều phiên bản Python cùng package (cp313, cp314).
"""
import os
import re
import sys
import html
from collections import defaultdict
from pathlib import Path


def normalize_name(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def parse_wheel(filename: str):
    if not filename.endswith(".whl"):
        return None
    parts = filename[:-4].split("-")
    if len(parts) < 5:
        return None
    name = parts[0]
    version = parts[1]
    return normalize_name(name), version


def gen(wheels_dir: Path, docs_dir: Path, owner: str, repo: str, tag: str):
    simple_dir = docs_dir / "simple"
    simple_dir.mkdir(parents=True, exist_ok=True)

    packages = defaultdict(list)
    wheel_files = sorted(wheels_dir.glob("*.whl"))
    if not wheel_files:
        print(f"⚠️  Không tìm thấy .whl trong {wheels_dir}")
        return

    for whl in wheel_files:
        parsed = parse_wheel(whl.name)
        if not parsed:
            print(f"⚠️  Skip: {whl.name}")
            continue
        name, version = parsed
        packages[name].append((version, whl.name))

    for name, entries in packages.items():
        pkg_dir = simple_dir / name
        pkg_dir.mkdir(parents=True, exist_ok=True)

        links = []
        for version, filename in sorted(entries, key=lambda x: x[1]):
            url = f"https://github.com/{owner}/{repo}/releases/download/{tag}/{filename}"
            links.append(f'    <a href="{html.escape(url)}">{html.escape(filename)}</a><br>')

        html_content = (
            "<!DOCTYPE html>\n"
            "<html>\n"
            "<head><meta charset=\"utf-8\"><title>Links for " + html.escape(name) + "</title></head>\n"
            "<body>\n"
            "<h1>Links for " + html.escape(name) + "</h1>\n"
            + "\n".join(links) + "\n"
            "</body>\n"
            "</html>\n"
        )
        (pkg_dir / "index.html").write_text(html_content, encoding="utf-8")
        print(f"✅ {name}: {len(entries)} wheel")

    root_links = "\n".join(
        f'    <a href="{html.escape(name)}/">{html.escape(name)}</a><br>'
        for name in sorted(packages.keys())
    )
    root = (
        "<!DOCTYPE html>\n"
        "<html>\n"
        "<head><meta charset=\"utf-8\"><title>Python Package Index</title></head>\n"
        "<body>\n"
        "<h1>Python Package Index</h1>\n"
        "<p>Tổng: " + str(len(packages)) + " package</p>\n"
        + root_links + "\n"
        "</body>\n"
        "</html>\n"
    )
    (simple_dir / "index.html").write_text(root, encoding="utf-8")
    print(f"✅ Root index: {len(packages)} package")

    (docs_dir / ".nojekyll").write_text("", encoding="utf-8")
    print("✅ .nojekyll")


if __name__ == "__main__":
    if len(sys.argv) < 6:
        print("Usage: gen_index.py <wheels_dir> <docs_dir> <owner> <repo> <tag>")
        sys.exit(1)

    gen(
        Path(sys.argv[1]),
        Path(sys.argv[2]),
        sys.argv[3],
        sys.argv[4],
        sys.argv[5],
    )