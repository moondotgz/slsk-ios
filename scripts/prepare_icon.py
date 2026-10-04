"""Generate the app's asset catalog from assets/icon.png on the macOS runner."""
import json
from pathlib import Path
import subprocess


def main():
    source = Path("assets/icon.png")
    if not source.is_file():
        raise SystemExit("Missing assets/icon.png")
    catalog = Path("App/Assets.xcassets")
    destination = catalog / "AppIcon.appiconset"
    destination.mkdir(parents=True, exist_ok=True)
    entries = []
    for idiom, sizes, scales in [
        ("iphone", [20, 29, 40, 60], [2, 3]),
        ("ipad", [20, 29, 40, 76], [1, 2]),
        ("ipad", [83.5], [2]),
        ("ios-marketing", [1024], [1]),
    ]:
        for size in sizes:
            for scale in scales:
                pixels = int(size * scale)
                filename = f"icon-{pixels}.png"
                if not (destination / filename).exists():
                    subprocess.run(["sips", "-z", str(pixels), str(pixels), str(source),
                                    "--out", str(destination / filename)], check=True)
                entries.append({"idiom": idiom, "size": f"{size}x{size}",
                                "scale": f"{scale}x", "filename": filename})
    info = {"version": 1, "author": "xcode"}
    (catalog / "Contents.json").write_text(json.dumps({"info": info}) + "\n")
    (destination / "Contents.json").write_text(json.dumps({"images": entries, "info": info}, indent=2) + "\n")


if __name__ == "__main__":
    main()
