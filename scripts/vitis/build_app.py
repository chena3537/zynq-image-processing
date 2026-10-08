"""
build_app.py

Recreates the Vitis workspace in build/vitis/ from build/image_pipeline.xsa
and builds the firmware.

The application component references firmware/ in place (no copy), so edits
made in the Vitis IDE land directly in the repo. Everything under
build/vitis/ is disposable and is deleted on each run.

Usage (from the repo root, after scripts/vivado/build.tcl):
    vitis -s scripts/vitis/build_app.py

Output:
    build/vitis/image_processing_app/build/image_processing_app.elf

Windows path length:
    The BSP build nests ~162 characters below <workspace>/<platform>, and the
    Arm toolchain fails beyond the 260-character MAX_PATH limit. If the repo
    is cloned deep enough to exceed it, set ZYNQ_VITIS_WS to a short
    directory (e.g. C:/zvws); scripts/hw/program.tcl honours the same variable.
"""

import os
import shutil
import stat
import subprocess
import sys

import vitis

REPO_ROOT    = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
XSA_FILE     = os.path.join(REPO_ROOT, "build", "image_pipeline.xsa")
WORKSPACE    = os.path.abspath(os.environ.get("ZYNQ_VITIS_WS",
                                              os.path.join(REPO_ROOT, "build", "vitis")))
FIRMWARE_DIR = os.path.join(REPO_ROOT, "firmware")

# Kept short: the platform name is part of the deepest BSP object paths.
PLATFORM_NAME = "plat"
DOMAIN_NAME   = "standalone_ps7_cortexa9_0"
APP_NAME      = "image_processing_app"

# Length of the deepest BSP build path below <workspace>/<platform>
# (.../gen_bsp/libsrc/standalone/src/CMakeFiles/.../cpputest_time.c.obj.d).
BSP_PATH_SUFFIX_LEN = 162
MAX_PATH = 259


def _stop_server(client):
    """On Windows the Vitis API starts its server through cmd.exe, and
    vitis.dispose() kills only that cmd.exe; the Java server survives and
    keeps the workspace locked. Kill the whole process tree instead."""
    proc = getattr(getattr(client, "_serverObj", None), "cp", None)
    if os.name == "nt" and proc is not None and proc.poll() is None:
        subprocess.run(["taskkill", "/F", "/T", "/PID", str(proc.pid)],
                       capture_output=True)


def _remove_readonly(func, path, _exc):
    # Vitis marks some generated BSP headers read-only; clear and retry.
    os.chmod(path, stat.S_IWRITE)
    func(path)


def main():
    if not os.path.isfile(XSA_FILE):
        sys.exit(f"XSA not found: {XSA_FILE} (run scripts/vivado/build.tcl first)")

    deepest = len(WORKSPACE) + 1 + len(PLATFORM_NAME) + BSP_PATH_SUFFIX_LEN
    if deepest > MAX_PATH:
        sys.exit(f"Workspace path too long for the BSP build ({deepest} > {MAX_PATH} chars): "
                 f"{WORKSPACE}\nSet ZYNQ_VITIS_WS to a shorter directory, e.g. C:/zvws")

    if os.path.isdir(WORKSPACE):
        shutil.rmtree(WORKSPACE, onexc=_remove_readonly)
    os.makedirs(WORKSPACE)

    client = vitis.create_client()
    try:
        client.set_workspace(path=WORKSPACE)

        platform = client.create_platform_component(
            name=PLATFORM_NAME,
            hw_design=XSA_FILE,
            os="standalone",
            cpu="ps7_cortexa9_0",
            domain_name=DOMAIN_NAME,
        )
        platform.build()

        xpfm = os.path.join(WORKSPACE, PLATFORM_NAME, "export", PLATFORM_NAME,
                            PLATFORM_NAME + ".xpfm")
        app = client.create_app_component(
            name=APP_NAME,
            platform=xpfm,
            domain=DOMAIN_NAME,
            template="empty_application",
        )
        app.import_files(from_loc=FIRMWARE_DIR, dest_dir_in_cmp="src",
                         is_skip_copy_sources=True)
        app.build()
    finally:
        _stop_server(client)
        vitis.dispose()

    elf = os.path.join(WORKSPACE, APP_NAME, "build", APP_NAME + ".elf")
    if not os.path.isfile(elf):
        sys.exit(f"Build finished but ELF not found: {elf}")
    print(f"Built: {elf}")


main()
