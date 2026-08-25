# -*- mode: python ; coding: utf-8 -*-


a = Analysis(
    ['app/desktop.py'],
    pathex=['/Users/sakura/TokenTracker'],
    binaries=[],
    datas=[('app/web', 'app/web'), ('web', 'web'), ('prices.json', '.'), ('quotas.json', '.')],
    hiddenimports=[
        # scanners 走 importlib 动态加载，PyInstaller 静态分析看不到，必须显式声明
        'tokentracker.scanners.claude', 'tokentracker.scanners.codex',
        'tokentracker.scanners.opencode', 'tokentracker.scanners.dsh',
        'tokentracker.scanners.hermes', 'tokentracker.scanners.kimi',
        'tokentracker.scanners.pi',
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='TokenTracker',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    icon=['assets/icon.icns'],
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=True,
    upx_exclude=[],
    name='TokenTracker',
)
app = BUNDLE(
    coll,
    name='TokenTracker.app',
    icon='assets/icon.icns',
    bundle_identifier='com.tokentracker.desktop',
    info_plist={
        # 状态栏常驻应用：默认不出现在 Dock（主面板打开时动态切回 Regular）
        'LSUIElement': True,
        'CFBundleName': 'TokenTracker',
        'CFBundleShortVersionString': '1.0.0',
    },
)
