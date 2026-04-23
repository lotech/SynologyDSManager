# Toolbar icons

Placeholder directory. Phase 3b-2 generates three PNGs from the existing
`SynologyDSManager Extension/ToolbarItemIcon.pdf`:

- `toolbar-48.png` — 48×48, template image (black-on-clear)
- `toolbar-96.png` — 96×96
- `toolbar-128.png` — 128×128

One-liner (from repo root) once 3b-2 wires the target:

```sh
sips -Z 128 "SynologyDSManager Extension/ToolbarItemIcon.pdf" \
    --out WebExtension/Resources/icons/toolbar-128.png
sips -Z 96  "SynologyDSManager Extension/ToolbarItemIcon.pdf" \
    --out WebExtension/Resources/icons/toolbar-96.png
sips -Z 48  "SynologyDSManager Extension/ToolbarItemIcon.pdf" \
    --out WebExtension/Resources/icons/toolbar-48.png
```

We're only shipping PNGs (not retina `@2x` variants) because Safari's
MV3 `icons` key already expects discrete sizes and handles DPI mapping.
