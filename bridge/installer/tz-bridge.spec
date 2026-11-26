# PyInstaller build for the bridge. Run from the repo root:
#   pyinstaller bridge/installer/tz-bridge.spec
# Gives dist/tz-bridge/tz-bridge.exe (a folder build: starts faster and trips antivirus less than one file).
from pathlib import Path

root = Path(SPECPATH).parent  # bridge/

a = Analysis(
    [str(root / "tz_bridge.py")],
    pathex=[str(root)],
    datas=[(str(root / "status.html"), "."), (str(root / "settings.html"), ".")],
    hiddenimports=["serial.tools.list_ports", "serial.tools.list_ports_windows"],
    excludes=["tkinter", "unittest", "pydoc"],
)
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, [], exclude_binaries=True, name="tz-bridge", console=True, upx=False,
          icon=str(Path(SPECPATH) / "tz-bridge.ico"))
coll = COLLECT(exe, a.binaries, a.datas, name="tz-bridge", upx=False)
