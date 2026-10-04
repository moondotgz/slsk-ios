"""Create an AltStore-compatible source from the actual release IPA metadata."""
import argparse
from datetime import datetime, timezone
import hashlib
import html
import json
from pathlib import Path
import plistlib
import shutil
from urllib.parse import quote
import zipfile


def generate(ipa, icon, repository, tag, site_url, output):
    with zipfile.ZipFile(ipa) as archive:
        candidates = [name for name in archive.namelist()
                      if name.startswith("Payload/") and name.endswith(".app/Info.plist")
                      and name.count("/") == 2]
        if len(candidates) != 1:
            raise ValueError("IPA must contain exactly one top-level app")
        info = plistlib.loads(archive.read(candidates[0]))
    base = site_url.rstrip("/")
    download = f"https://github.com/{repository}/releases/download/{quote(tag, safe='')}/{quote(ipa.name)}"
    date = datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    version = {"version": info["CFBundleShortVersionString"],
               "buildVersion": info["CFBundleVersion"], "date": date,
               "downloadURL": download, "size": ipa.stat().st_size,
               "sha256": hashlib.sha256(ipa.read_bytes()).hexdigest(),
               "minOSVersion": info["MinimumOSVersion"],
               "localizedDescription": f"Automated main build {tag}. Signed on-device by your sideloading app."}
    app = {"name": "Slsk", "bundleIdentifier": info["CFBundleIdentifier"],
           "developerName": repository.split("/")[0],
           "localizedDescription": "Native Soulseek client for iOS with Liquid Glass, search, chat and resumable downloads.",
           "iconURL": f"{base}/icon.png", "tintColor": "F58220",
           "appPermissions": {"entitlements": [], "privacy": []},
           "versions": [version],
           "version": version["version"], "versionDate": date,
           "downloadURL": download, "size": version["size"]}
    source = {"name": "Slsk", "identifier": f"{repository.replace('/', '.')}.source",
              "sourceURL": f"{base}/source.json", "website": f"https://github.com/{repository}",
              "iconURL": app["iconURL"], "apps": [app], "news": []}
    output.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(icon, output / "icon.png")
    (output / "source.json").write_text(json.dumps(source, indent=2) + "\n")
    (output / "index.html").write_text(f"""<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Slsk update source</title>
<style>body{{font:18px system-ui;max-width:42rem;margin:4rem auto;padding:0 1rem;background:#141414;color:#eee}}a{{color:#ffae65}}img{{border-radius:24px}}</style>
<img src="icon.png" width="96" height="96" alt="Slsk icon"><h1>Slsk for iOS</h1>
<p>Add this source URL in Flarestore, SideStore, or AltStore:</p>
<p><a href="source.json">{html.escape(base)}/source.json</a></p>
<p>Latest version: {html.escape(version['version'])}</p>
<p><a href="{html.escape(download, quote=True)}">Download unsigned IPA</a></p>
<p>Sign using your existing certificate. Keep the bundle identifier and signing identity unchanged when updating; do not uninstall first.</p></html>
""")
    (output / ".nojekyll").touch()
    return source


def main():
    parser = argparse.ArgumentParser()
    for name in ["ipa", "icon", "repository", "tag", "site-url", "output"]:
        parser.add_argument(f"--{name}", required=True)
    args = parser.parse_args()
    generate(Path(args.ipa), Path(args.icon), args.repository, args.tag, args.site_url, Path(args.output))


if __name__ == "__main__":
    main()
