"""Moves the bundled scrcpy to its latest release: the pinned version and hash in
macos/scripts/fetch-scrcpy.sh, and the versions THIRD-PARTY-NOTICES.md names. Reads the release
JSON on stdin and SHA256SUMS.txt from argv[1]. Prints the new version, or nothing when current."""
import json, re, sys
from pathlib import Path

release = json.load(sys.stdin)
new = release["tag_name"].lstrip("v")
script = Path("macos/scripts/fetch-scrcpy.sh")
text = script.read_text()
old = re.search(r'^VERSION="([^"]+)"', text, re.M).group(1)
if new == old:
    sys.exit(0)
name = f"scrcpy-macos-aarch64-v{new}.tar.gz"
sums = Path(sys.argv[1]).read_text()
sha = next(l.split()[0] for l in sums.splitlines() if l.strip().endswith(name))
assert re.fullmatch(r"[0-9a-f]{64}", sha), sha
text = re.sub(r'^VERSION=".*"', f'VERSION="{new}"', text, flags=re.M)
text = re.sub(r'^SHA256=".*"', f'SHA256="{sha}"', text, flags=re.M)
script.write_text(text)

notices = Path("THIRD-PARTY-NOTICES.md")
n = notices.read_text().replace(f"scrcpy {old}", f"scrcpy {new}").replace(f"/v{old}/", f"/v{new}/")
n = n.replace(f"/tree/v{old}", f"/tree/v{new}")
body = release.get("body") or ""
# The release notes name the upgraded components ("Upgrade FFmpeg to 9.0.2").
for component, link in [
    ("FFmpeg", r"(ffmpeg-)[\d.]+(\.tar\.xz)"),
    ("SDL", r"(release-)[\d.]+()"),
    ("libusb", r"(libusb/tree/v)[\d.]+()"),
]:
    m = re.search(rf"Upgrade {component} to ([\d.]+)", body)
    if not m:
        continue
    v = m.group(1)
    n = re.sub(rf"\| {component} \| [^|]+ \|", f"| {component} | {v} |", n)
    n = re.sub(link, rf"\g<1>{v}\g<2>", n)
m = re.search(r"Upgrade platform-tools \(adb\) to ([\d.]+)", body)
if m:
    n = re.sub(r"platform-tools [\d.]+\b", f"platform-tools {m.group(1)}", n)
    n = re.sub(r"platform-tools_r[\d.]+-darwin", f"platform-tools_r{m.group(1)}-darwin", n)
notices.write_text(n)
print(new)
