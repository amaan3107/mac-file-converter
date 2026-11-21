# The Converter

A small Mac app that converts files locally — no uploading to websites.

## Right-click in Finder
Select one or more files, right-click → **Quick Actions** (or **Services**):

| Item | What it does |
|---|---|
| **Convert with The Converter** | Opens the window with all the options below |
| **Convert to JPG** | Photos and PDFs → JPG, instantly, no window |
| **Convert to PDF** | Photos and Word/text documents → PDF |
| **Combine into PDF** | Merges the selected photos, PDFs and documents into one `Combined.pdf` |
| **Convert to MP4** | Videos → MP4 (H.264, accepted everywhere) |
| **Convert to MP3** | Audio or video → MP3 |

One-click actions show a notification when done; click it to see the file in Finder.

## The window
- Pick a format per file, or **Convert all to** for the whole list.
- **File size** — shrinks photos, PDFs, videos and audio to fit an upload limit (Under 200 KB … Under 25 MB).
  Use the same format (e.g. JPG → JPG) to just make a file smaller.
- **Resize** — caps the longest side of photos and videos.
- **Remove location** — strips GPS location from photos and videos (on by default).
- **Combine into PDF** — appears with 2+ photos/PDFs/documents; drag rows to set the page order.
- **Cancel** stops a long conversion.
- **Move original to Trash after converting** (on by default) sends old files to the Trash, recoverable.
  If the new file was only renamed to avoid a clash (e.g. `photo (1).jpg`), it takes back the original name.

## Formats
| From | To |
|---|---|
| Images (HEIC, PNG, JPG, WEBP, TIFF, GIF…) | JPG, PNG, HEIC, PDF, WEBP, TIFF, GIF, BMP |
| PDF | PDF (smaller), JPG, PNG, TIFF, HEIC (one image per page) |
| Documents (DOCX, DOC, RTF, TXT, HTML, ODT) | PDF, DOCX, RTF, TXT |
| Video (MOV, MP4, MKV, AVI…) | MP4, MOV, M4V, animated GIF, MP3/M4A/WAV (audio only) |
| Audio (M4A, MP3, WAV, FLAC, AIFF…) | MP3, M4A, WAV, AAC, FLAC, AIFF |

Images, PDFs and documents use macOS's built-in frameworks. Audio/video use `ffmpeg`, WEBP uses `cwebp`
(`brew install ffmpeg webp`). Pages files aren't supported — export them from Pages first.

## Rebuild
```bash
./build.sh
```
Compiles the app, installs it to `~/Applications/The Converter.app`, and registers the right-click actions.
`Tools/make_plist.py` regenerates `Info.plist` if you change the right-click menu.

## License
MIT — see [LICENSE](LICENSE).
