#!/usr/bin/env python3
"""Builds the Keo app icon: three SVG masters and the 1024 PNGs Xcode expects.

One source of truth for the geometry, because the light, dark and tinted
variants must stay identical in shape — only their palette differs.

Run:  python3 Design/icon/build.py
"""
import pathlib
import subprocess

HERE = pathlib.Path(__file__).parent
ICONSET = HERE.parent.parent / "Keo/Assets.xcassets/AppIcon.appiconset"

# The mark, on a 256 grid. The cage is the NAS; the four bays are its drives.
CAGE = 'x="56" y="58" width="54" height="136" rx="14"'
BAYS = [66, 98, 130, 162]

# The arm, expanded from a 26-wide round-capped stroke through (186,78) (138,126) (186,174)
# so the masters carry no strokes: two 180 degree caps, a round outer join, a mitred inner apex.
ARM = ("M 176.81 68.81 L 128.81 116.81 A 13 13 0 0 0 128.81 135.19 "
       "L 176.81 183.19 A 13 13 0 0 0 195.19 164.81 L 156.38 126 "
       "L 195.19 87.19 A 13 13 0 0 0 176.81 68.81 Z")

# Apple masks the corners itself, so the light icon is a full square with no radius.
# Dark and tinted ship on transparency: the system draws its own dark backdrop under them.
VARIANTS = {
    "light":  dict(bg="#e9a178", cage="#cf8154", mark="#ffffff"),
    "dark":   dict(bg=None,      cage="#7a4a30", mark="#e9a178"),
    "tinted": dict(bg=None,      cage="#6e6e6e", mark="#ffffff"),
}


def svg(bg, cage, mark):
    body = f'  <rect width="256" height="256" fill="{bg}"/>\n' if bg else ""
    body += f'  <rect {CAGE} fill="{cage}"/>\n'
    body += f'  <g fill="{mark}">\n'
    for y in BAYS:
        body += f'    <rect x="64" y="{y}" width="38" height="24" rx="5"/>\n'
    body += "  </g>\n"
    body += f'  <path fill="{mark}" d="{ARM}"/>\n'
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" '
            'width="1024" height="1024">\n  <title>Keo</title>\n' + body + "</svg>\n")


def main():
    ICONSET.mkdir(parents=True, exist_ok=True)
    for name, palette in VARIANTS.items():
        src = HERE / f"keo-{name}.svg"
        src.write_text(svg(**palette))
        subprocess.run(
            ["rsvg-convert", "-w", "1024", "-h", "1024",
             "-o", str(ICONSET / f"keo-{name}-1024.png"), str(src)],
            check=True)
        print(f"{name:7} -> {src.name}, keo-{name}-1024.png")

    (ICONSET / "Contents.json").write_text("""{
  "images" : [
    {
      "filename" : "keo-light-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [
        { "appearance" : "luminosity", "value" : "dark" }
      ],
      "filename" : "keo-dark-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [
        { "appearance" : "luminosity", "value" : "tinted" }
      ],
      "filename" : "keo-tinted-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
""")
    print("Contents.json -> Any / Dark / Tinted")


if __name__ == "__main__":
    main()
