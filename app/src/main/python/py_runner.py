# -*- coding: utf-8 -*-
"""
py_runner.py — Helper chạy code Python + pip install cho Mini-Y2mate.
Gọi qua PythonBridge.callFunction("py_runner", ...).
"""

import io
import json
import os
import sys
import traceback
from contextlib import redirect_stdout, redirect_stderr

# Namespace giữ giữa các lần chạy (giống REPL)
_GLOBALS = {"__name__": "__main__"}


def run_code(args_json):
    try:
        args = json.loads(args_json)
    except Exception:
        args = {}
    code = args.get("code", "")
    if not code.strip():
        return json.dumps({"success": False, "output": "(code rỗng)"})

    buf_out = io.StringIO()
    buf_err = io.StringIO()
    try:
        compiled = compile(code, "<mini-y2mate>", "exec")
        with redirect_stdout(buf_out), redirect_stderr(buf_err):
            exec(compiled, _GLOBALS)
        out = buf_out.getvalue() + buf_err.getvalue()
        if not out:
            out = "(không có output)"
        return json.dumps({"success": True, "output": out})
    except SystemExit as e:
        out = buf_out.getvalue() + buf_err.getvalue()
        return json.dumps({"success": True, "output": out + f"\n[exit {e.code}]"})
    except Exception:
        out = buf_out.getvalue() + buf_err.getvalue()
        out += traceback.format_exc()
        return json.dumps({"success": False, "output": out})


def reset_namespace(args_json="{}"):
    global _GLOBALS
    _GLOBALS = {"__name__": "__main__"}
    return json.dumps({"success": True, "output": "Đã reset namespace"})


def install_package(args_json):
    try:
        args = json.loads(args_json)
    except Exception:
        args = {}
    pkg = args.get("package", "").strip()
    upgrade = bool(args.get("upgrade", False))
    if not pkg:
        return json.dumps({"success": False, "output": "Thiếu tên package"})

    buf_out = io.StringIO()
    buf_err = io.StringIO()
    try:
        from pip._internal.cli.main import main as pip_main
    except Exception as e:
        return json.dumps({"success": False, "output": f"pip không khả dụng: {e}"})

    argv = ["install", "--no-cache-dir", "--disable-pip-version-check", pkg]
    if upgrade:
        argv.insert(1, "--upgrade")

    rc = 1
    try:
        with redirect_stdout(buf_out), redirect_stderr(buf_err):
            try:
                rc = pip_main(argv) or 0
            except SystemExit as e:
                rc = e.code if isinstance(e.code, int) else 1
    except Exception:
        out = buf_out.getvalue() + buf_err.getvalue() + traceback.format_exc()
        return json.dumps({"success": False, "output": out})

    out = buf_out.getvalue() + buf_err.getvalue()
    return json.dumps({
        "success": rc == 0,
        "output": out or f"pip exit code {rc}",
        "rc": rc,
    })


def uninstall_package(args_json):
    try:
        args = json.loads(args_json)
    except Exception:
        args = {}
    pkg = args.get("package", "").strip()
    if not pkg:
        return json.dumps({"success": False, "output": "Thiếu tên package"})

    buf_out = io.StringIO()
    buf_err = io.StringIO()
    try:
        from pip._internal.cli.main import main as pip_main
        rc = 1
        with redirect_stdout(buf_out), redirect_stderr(buf_err):
            try:
                rc = pip_main(["uninstall", "-y", pkg]) or 0
            except SystemExit as e:
                rc = e.code if isinstance(e.code, int) else 1
        out = buf_out.getvalue() + buf_err.getvalue()
        return json.dumps({"success": rc == 0, "output": out, "rc": rc})
    except Exception:
        out = buf_out.getvalue() + buf_err.getvalue() + traceback.format_exc()
        return json.dumps({"success": False, "output": out})


def list_packages(args_json="{}"):
    try:
        import importlib.metadata as md
        pkgs = []
        for dist in md.distributions():
            try:
                name = dist.metadata["Name"]
                ver = dist.version
                if name:
                    pkgs.append(f"{name}=={ver}")
            except Exception:
                pass
        pkgs.sort(key=lambda s: s.lower())
        return json.dumps({"success": True, "packages": pkgs, "count": len(pkgs)})
    except Exception:
        return json.dumps({"success": False, "output": traceback.format_exc()})


def check_import(args_json):
    try:
        args = json.loads(args_json)
    except Exception:
        args = {}
    module = args.get("module", "").strip()
    if not module:
        return json.dumps({"success": False, "output": "Thiếu tên module"})
    try:
        import importlib
        importlib.import_module(module)
        return json.dumps({"success": True, "output": f"{module} OK"})
    except Exception as e:
        return json.dumps({"success": False, "output": f"{module}: {e}"})


def env_info(args_json="{}"):
    import platform
    info = {
        "python": sys.version.split()[0],
        "version_info": list(sys.version_info[:3]),
        "executable": sys.executable,
        "prefix": sys.prefix,
        "platform": platform.platform(),
        "machine": platform.machine(),
        "sys_path_0": sys.path[0] if sys.path else "",
    }
    return json.dumps({"success": True, "info": info})
