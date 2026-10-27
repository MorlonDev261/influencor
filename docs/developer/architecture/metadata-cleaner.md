# Metadata cleaner ("Deganeo")

Code: `lib/features/cleaner/` — `domain/` (report + options), `data/` (format
handlers, detector, pipeline), `application/` (isolate-backed service),
`presentation/` (page + report card). Tests: `test/cleaner/`
(`metadata_leaks_test.dart` holds the regressions of metadata that used to
survive a clean).

**Scope:** Deganeo only takes files of the current workspace. The page's
picker opens the in-app gallery confined to the workspace on every platform
(`AppFilePicker.pick(root: …)`), dropped files from elsewhere are refused with
a message (`isInWorkspace`), and cleaned copies are stored through
`LibraryController.storeCleaned` so the library refreshes. Degany's
`deganeo_*` tools follow the same rule.

## Strategy: lossless, allowlist-based, verified

No pixel is decoded or re-encoded (no quality loss, works on large files). Each
handler walks the *real* structure of its container and keeps only what is
needed to render/play; everything else is dropped or blanked **and reported**.
Unknown elements are removed by default, never kept by default. Malformed input
throws `FormatException` → `failed`; content we recognise but cannot clean
safely throws `UnsupportedContent` → `unsupported`. In both cases no output
file is produced and the original is untouched.

| Format | Kept | Removed / blanked |
|---|---|---|
| JPEG | image segments, JFIF header (16 bytes: thumbnail and any trailing bytes cut), Adobe APP14 (14 bytes), ICC (option) | EXIF, XMP, IPTC, COM, MPF, other APPn, data after EOI |
| PNG | rendering chunks, iCCP (option), APNG | tEXt/zTXt/iTXt (prompts…), tIME, eXIf, XMP, C2PA, unknown ancillary, data after IEND |
| WebP | image/animation chunks, ICCP (option); VP8X flags fixed | EXIF, XMP, unknown |
| GIF | image data, graphic control, loop extension (loop-count sub-block only) | comments, plain-text, XMP/vendor extensions, extra sub-blocks of the loop extension |
| TIFF | pixel tags only (allowlist), edited **in place** | Make/Model/Software/dates/artist/XMP/IPTC/GPS/Exif IFD (bytes zeroed), then every byte no kept IFD points to (old IFDs of in-place edits, maker-note data outside the Exif IFD) zeroed. RAW/DNG/BigTIFF refused |
| MP4 / MOV / M4V | ftyp, moov(mvhd, tracks…), mdat, moof (absolute `tfhd` base offsets remapped; a fragmented file whose dropped GPS/sensor track has fragments is refused) | `udta`, `meta` (GPS, make, model, Live-Photo id), uuid/XMP, padding, timed-metadata tracks **and their bytes in `mdat` (zeroed)**; timestamps, handler names and codec compressor names blanked; x264/HEVC user-data SEI turned into same-length filler NALs; `stco`/`co64` remapped |
| HEIC / AVIF | image items, properties, `iloc` remapped | `Exif` / `mime` (XMP) / `uri` items removed from `iinf`/`iloc`/`iref`/`ipma`, their bytes zeroed |
| MKV / WebM | everything | in **every** Segment: Tags, Info (Title, MuxingApp, WritingApp, DateUTC, file links), track names — overwritten in place by EBML `Void` of identical size (no offset moves), CRC-32 elements invalidated by an edit; data after the Segments voided |
| AVI | `hdrl`/`strl`/`odml` headers, `movi`, `idx1` | `LIST INFO` (also nested in `hdrl`), `IDIT`, `ISMP`, stream names `strn`, unknown chunks/lists (`LIST ncdt`…), content of `JUNK` — all turned **in place** into zero-filled `JUNK` of the same size, so `idx1` and the OpenDML `indx` (absolute offsets) stay valid; data after RIFF dropped |
| PDF | everything reachable from `/Root`, rewritten as a fresh classic file | Info dict, XMP, `/PieceInfo`, thumbnails, annotation author/date (also without the optional `/Type /Annot`), `/CreationDate` / `/ModDate` anywhere (embedded files' `/Params`…), trailer `/ID`, **obsolete objects of incremental saves**, EXIF/XMP inside embedded JPEG images. Encrypted PDFs refused |

**Orientation:** the app runs with `CleanOptions.stripAll`: no ICC profile and no orientation flag. For JPEG the EXIF rotation is *baked into the pixels losslessly* (`jpeg_rotate.dart`): quantised DCT coefficients are transposed / mirrored (sign flips on odd frequencies, quant tables transposed for 90-degree cases) and re-entropy-coded with freshly optimised Huffman tables, so nothing is re-compressed. It needs baseline Huffman, a single scan and, on a mirrored axis, dimensions that are a whole number of MCUs (true for most camera photos). Otherwise (progressive, odd sizes) it falls back to a minimal EXIF holding only the orientation and reports `CleanCaveat.orientationFlagKept`. PNG / WebP cannot rotate pixels, so they keep the minimal flag (`CleanOptions.keepOrientationFlag`). Library defaults (`preserveOrientation`) are unchanged.
