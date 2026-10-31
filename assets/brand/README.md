# Tamebar identity (placeholder)

A neutral placeholder until a real icon is chosen: a rounded square holding a horizontal bar and a dot,
in `#1d1d1f` on `#f5f5f7`. It is drawn as plain vector geometry and stays legible at 16 px.

- `Tamebar.icon/Assets/Mark.svg`: unmasked, transparent foreground at 1024 × 1024.
- `Tamebar.icon/Assets/Background.svg`: opaque, full-bleed `#f5f5f7` layer.
- `Tamebar.icon/icon.json`: prepared layered Icon Composer document.
- `app-icon.png`: sRGB 1024px fallback icon for the existing macOS 14+ bundle.

The legacy ICNS uses the familiar macOS inset rounded tile; the layered sources have no baked corner mask.
The layered document is not yet included in the app: first-use Apple licence acceptance is pending.

Regenerate the fallback PNG from the SVG, then generate every native ICNS size:

```sh
swift scripts/render-icon.swift assets/brand/app-icon.png
./scripts/build-icon.sh
```

The menu bar loads `Mark.svg` as a template image, so only its shape counts there and it works in light and
dark appearances. The dashboard and tray load the bundled ICNS.
