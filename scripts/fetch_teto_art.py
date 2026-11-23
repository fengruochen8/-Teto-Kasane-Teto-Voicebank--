"""Prepare the official welcome illustration for a personal TetoMelody build."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from urllib.request import urlopen

SOURCE_URL = "https://kasaneteto.jp/assets/download/illust-logo/official_illust_teto_new.png"
SOURCE_SHA256 = "3fe84bda38b86fcac79822d285f0851ac2491f08630ed785be0ddcfd2fa9d703"
SOURCE_SIZE = 5_786_704
IMAGE_NAME = "OfficialTetoUTAU.png"
MANIFEST = {
    "images": [{"filename": IMAGE_NAME, "idiom": "universal"}],
    "info": {"author": "xcode", "version": 1},
}


def load_source(local_original):
    if local_original.is_file():
        payload = local_original.read_bytes()
    else:
        with urlopen(SOURCE_URL, timeout=30) as response:
            payload = response.read(SOURCE_SIZE + 1)
    if len(payload) != SOURCE_SIZE or hashlib.sha256(payload).hexdigest() != SOURCE_SHA256:
        raise SystemExit("官方原图校验失败，请核对官网配布页后再试。")
    return payload


def prepare_image(source, destination):
    sips = shutil.which("sips") if sys.platform == "darwin" else None
    if sips:
        subprocess.run(
            [sips, "-s", "format", "png", "-Z", "2048", str(source), "--out", str(destination)],
            check=True,
        )
        return

    try:
        from PIL import Image
    except ImportError:
        raise SystemExit("此环境需要 Pillow 才能缩放图片。安装命令为 python -m pip install Pillow。")
    with Image.open(source) as original:
        artwork = original.convert("RGBA")
        artwork.thumbnail((2048, 2048), Image.Resampling.LANCZOS)
        artwork.save(destination, format="PNG", optimize=True)


def main():
    root = Path(__file__).resolve().parent.parent
    target = root / "App" / "Assets.xcassets" / "TetoWelcomeIllustration.imageset"
    local_art = root / "LocalArtwork"
    if target.exists():
        if (target / IMAGE_NAME).is_file() and (target / "Contents.json").is_file():
            print(f"已存在欢迎页资源，保留 {target}")
            return
        raise SystemExit(f"已有不完整的资源目录，请先检查 {target}。")

    local_art.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".prepare-teto-", dir=local_art) as directory:
        stage = Path(directory)
        source = stage / IMAGE_NAME
        source.write_bytes(load_source(local_art / IMAGE_NAME))
        bundle = stage / target.name
        bundle.mkdir()
        prepare_image(source, bundle / IMAGE_NAME)
        (bundle / "Contents.json").write_text(
            json.dumps(MANIFEST, indent=2) + "\n", encoding="utf-8"
        )
        bundle.rename(target)
    print(f"已生成欢迎页资源 {target}")


if __name__ == "__main__":
    main()
