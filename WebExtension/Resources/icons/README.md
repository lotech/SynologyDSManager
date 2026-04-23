# Toolbar icons

Placeholder directory. Phase 3b-2 generates three PNGs from the existing
`SynologyDSManager Extension/ToolbarItemIcon.pdf`:

- `toolbar-48.png` — 48×48, template image (black-on-clear)
- `toolbar-96.png` — 96×96
- `toolbar-128.png` — 128×128

Two-step `sips` pipeline (from repo root). A one-shot `sips -Z N` on a
PDF writes the PDF rasterised at its native size three times instead of
resizing, so we rasterise to a high-res PNG once and downscale with
`-z H W` (the forced-resize flavour):

```sh
sips -s format png "SynologyDSManager Extension/ToolbarItemIcon.pdf" \
    --out /tmp/toolbar-source.png

sips -z 128 128 /tmp/toolbar-source.png \
    --out WebExtension/Resources/icons/toolbar-128.png
sips -z  96  96 /tmp/toolbar-source.png \
    --out WebExtension/Resources/icons/toolbar-96.png
sips -z  48  48 /tmp/toolbar-source.png \
    --out WebExtension/Resources/icons/toolbar-48.png

rm /tmp/toolbar-source.png
```

We're only shipping PNGs (not retina `@2x` variants) because Safari's
MV3 `icons` key already expects discrete sizes and handles DPI mapping.
