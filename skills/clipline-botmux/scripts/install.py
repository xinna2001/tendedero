"""Install the independent ClipLine build from its owner's GitHub repository."""
import hashlib
import json
import os
import plistlib
import shutil
import stat
import subprocess
import tempfile
import urllib.error
import urllib.request
import zipfile
from pathlib import Path, PurePosixPath

REPOSITORY = "xinna2001/tendedero"
APP_ID = "com.xinna2001.ClipLine"
VERSION = "1.8.0"
SOURCE_REF = "v1.8.0"


def app_version(app):
    try:
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        if info.get("CFBundleIdentifier") != APP_ID:
            return None
        if not (app / "Contents/MacOS/ClipLine").is_file():
            return None
        return tuple(int(x) for x in info["CFBundleShortVersionString"].split("."))
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException):
        return None


def fetch(url, limit=64 * 1024 * 1024):
    request = urllib.request.Request(url, headers={"User-Agent": "ClipLine-Botmux/1.7.0"})
    with urllib.request.urlopen(request, timeout=45) as response:
        data = response.read(limit + 1)
    if len(data) > limit:
        raise RuntimeError("下载文件超过允许大小。")
    return data


def release_app(work):
    try:
        release = json.loads(fetch(f"https://api.github.com/repos/{REPOSITORY}/releases/latest", 2_000_000))
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        if error.code in (403, 429):
            if shutil.which("gh"):
                result = subprocess.run(["gh", "api", f"repos/{REPOSITORY}/releases/latest"],
                                        capture_output=True, timeout=45)
                if result.returncode == 0:
                    release = json.loads(result.stdout)
                else:
                    return None
            else:
                return None
        else:
            raise
    assets = release.get("assets", [])
    asset = next((a for a in assets if a["name"].startswith("ClipLine-") and a["name"].endswith("-macos-universal.zip")), None)
    if asset is None:
        return None
    prefix = f"https://github.com/{REPOSITORY}/releases/download/"
    url = asset["browser_download_url"]
    if not url.startswith(prefix):
        raise RuntimeError("安装包下载地址不属于自有仓库。")
    expected = (asset.get("digest") or "").removeprefix("sha256:")
    if len(expected) != 64:
        sums = next((a for a in assets if a["name"] == "SHA256SUMS.txt"), None)
        if sums is None or not sums["browser_download_url"].startswith(prefix):
            raise RuntimeError("安装包缺少 SHA-256 校验信息。")
        expected = next((line.split()[0] for line in fetch(sums["browser_download_url"], 32_000).decode().splitlines()
                         if line.split()[-1].lstrip("*") == asset["name"]), "")
    archive = fetch(url)
    if hashlib.sha256(archive).hexdigest() != expected.lower():
        raise RuntimeError("安装包 SHA-256 校验失败。")
    path = work / "release.zip"
    path.write_bytes(archive)
    unpack = work / "unpacked"
    unpack.mkdir()
    with zipfile.ZipFile(path) as bundle:
        total = sum(info.file_size for info in bundle.infolist())
        if total > 256 * 1024 * 1024:
            raise RuntimeError("安装包展开后过大。")
        for info in bundle.infolist():
            member = PurePosixPath(info.filename)
            if member.parts and member.parts[0] == "__MACOSX":
                continue
            if member.is_absolute() or ".." in member.parts or not member.parts or member.parts[0] != "ClipLine.app":
                raise RuntimeError("安装包包含越界路径。")
            mode = info.external_attr >> 16
            if stat.S_ISLNK(mode):
                raise RuntimeError("安装包包含非预期的符号链接。")
            target = unpack.joinpath(*member.parts)
            if info.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(bundle.read(info))
                target.chmod(mode & 0o777 or 0o644)
    return unpack / "ClipLine.app"


def ensure_app(install_root=None, explicit_app=None, source_app=None):
    if explicit_app:
        app = Path(explicit_app).expanduser().resolve()
        if not app_version(app):
            raise RuntimeError(f"不是可用的 ClipLine 应用：{app}")
        return app
    root = Path(install_root).expanduser() if install_root else Path.home() / "Applications"
    destination = root / "ClipLine.app"
    minimum = tuple(map(int, VERSION.split(".")))
    if not source_app and (app_version(destination) or (0,)) >= minimum:
        return destination
    if destination.exists():
        raise RuntimeError("已有图绳版本需要更新，请先退出应用并保留旧包，再安装新版；便签数据独立保存在 Application Support。")
    root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="clipline-install-") as temporary:
        work = Path(temporary)
        app = Path(source_app).resolve() if source_app else release_app(work)
        if app is None:
            source = work / "source"
            subprocess.run(["git", "clone", "--depth", "1", "--branch", SOURCE_REF,
                            f"https://github.com/{REPOSITORY}.git", str(source)], check=True)
            subprocess.run(["bash", "scripts/build-app.sh", "release"], cwd=source, check=True)
            app = source / "build/ClipLine.app"
        if (app_version(app) or (0,)) < minimum:
            raise RuntimeError("下载或构建的应用版本无效。")
        staging = root / (".ClipLine-install-" + os.urandom(6).hex() + ".app")
        try:
            shutil.copytree(app, staging)
            (staging / "Contents/MacOS/ClipLine").chmod(0o755)
            subprocess.run(["codesign", "--verify", "--deep", str(staging)], check=True, capture_output=True)
            os.rename(staging, destination)
        finally:
            if staging.exists():
                shutil.rmtree(staging)
    return destination
