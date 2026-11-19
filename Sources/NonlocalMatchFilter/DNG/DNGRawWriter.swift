import Foundation

/// Writes a DNG whose **pixels are new and whose metadata is not**.
///
/// The one rule this type exists to enforce: *copy every tag, rewrite only what the file layout
/// forces you to rewrite.* A denoise pass changes sample values and nothing else, so anything that
/// describes geometry, colour or optics has to arrive at the far end untouched — in particular
///
///  - `50714 BlackLevel` / `50717 WhiteLevel` (the value range the samples live in),
///  - `50829 ActiveArea` / `50719` `50720` `DefaultCrop*` (what part of the sensor is the picture),
///  - `51022 OpcodeList2` (vignette/gain correction) and `51041 OpcodeList3`
///    (`WarpRectilinear`, the lens-distortion model),
///  - `50721`/`50722 ColorMatrix1/2`, `50964`/`50965 ForwardMatrix1/2`, `50728 AsShotNeutral`,
///  - `700 XMP`, `50740 DNGPrivateData`, the EXIF and GPS sub-IFDs, and the embedded preview.
///
/// Tags that **cannot** be copied, because they describe a layout that no longer exists:
///
/// | tag | why |
/// |---|---|
/// | `273` `279` StripOffsets/ByteCounts, `278` RowsPerStrip | strips are gone; this writes tiles |
/// | `322`–`325` TileWidth/Length/Offsets/ByteCounts | the tile grid and the compressed sizes are new |
/// | `254` `256` `257` `258` `259` `262` `277` `284` `339` | size / depth / compression / photometric describe *this* file |
/// | `330` SubIFDs | the chain is rebuilt here, not carried over |
/// | `34665` `34853` ExifIFD/GPS | the data is copied verbatim, only the pointers move |
///
/// Keep the copy list honest by construction: `preserved` in `write(primary:alternate:)` starts from
/// *all* source tags and then subtracts `layoutTags`, so a tag nobody thought about is preserved by
/// default rather than dropped by omission.
///
/// ## Two raw images in one file (`write(primary:alternate:…)`)
///
/// A denoised RAW that keeps its input is two full-resolution mosaics of the same sensor. Both go in
/// one DNG as `SubIFDs` of IFD0, and IFD0 itself becomes the **preview** page — the shape a camera
/// writes:
///
/// ```text
/// IFD0            preview (NewSubfileType = 1); holds the global metadata, EXIF/GPS and `330`
///   SubIFDs[0]    original mosaic (NewSubfileType = 0, CFA, lossless JPEG)
///   SubIFDs[1]    alternate mosaic — the denoised one, CFA, NewSubfileType = 1
/// ```
///
/// **Order is the whole point, and it was measured, not assumed.** `ImageIO`/`CIRAWFilter` scan the
/// `SubIFDs` array and decode the first `NewSubfileType = 0` raw they find; IFD0 is consulted only
/// when the array holds none (verified by swapping two raws between IFD0 and `SubIFDs` — the decoder
/// followed the array both times). So the original has to sit at `SubIFDs[0]`: every standard reader
/// then shows the *negative*, sample-exact, and the denoised copy is additive — visible only to a
/// reader that asks for `SubIFDs[1]` or promotes it. The other order would make every viewer
/// silently open the filtered image, with no way back to the original.
///
/// The alternate's `NewSubfileType` is `1`, not `0`, and that too was measured. With **two**
/// `NewSubfileType = 0` raws in `SubIFDs`, `CIRAWFilter` stops rendering the raw faithfully: a file
/// built that way decodes to the same mean but max|diff| 255 / rms 21.6 against the source (and does
/// so even when both array entries point at the *same* IFD, so it is the second subfiletype-0 raw
/// that changes the interpretation, not which page is picked). Marking the alternate `1` — the tag's
/// "not the main image" bit — makes the same bytes decode exactly: max|diff| 0 across the frame.
/// Nothing is lost: the page keeps its CFA tags, its pixel tag 330 is unreachable by accident, and
/// promoting it (setting `254 = 0`, which is what `dng-promote-subifd` and any "pick a layer" code
/// does) makes it the decoded image.
///
/// Because IFD0 is a preview in that layout, each raw page describes itself: it carries the source
/// raw's CFA / black-level / crop / opcode tags as well as its own pixel tags, which is what a
/// camera DNG's raw SubIFD looks like. File-global metadata — `700` XMP, EXIF and GPS — lives only in
/// IFD0, where readers look for it.
///
/// The single-image path is unaffected: `alternate == nil` produces the pre-existing layout
/// (`IFD0` = raw, `IFD1` = preview) byte for byte.
///
/// Compression is `7` (lossless JPEG). Measured on a 60 MP frame with a 256×256 tile grid:
/// uncompressed 121 MB, `8` Deflate 86 MB, `7` SOF3 **57 MB** — and Core Image refuses the Deflate
/// file outright (`CIRAWFilter.nativeSize` comes back `0×0`, `outputImage` nil), so `7` is not just
/// smaller, it is the only compressed form the system decoder accepts.
public enum DNGRawWriter {

    public enum WriteError: Error, CustomStringConvertible {
        case notATIFF
        case missingTag(UInt16)
        case unexpectedLayout(String)
        case pixelCountMismatch(expected: Int, got: Int)

        public var description: String {
            switch self {
            case .notATIFF: return "源文件不是 TIFF/DNG（字节序标记缺失）"
            case .missingTag(let t): return "源文件缺少必需的 tag \(t)"
            case .unexpectedLayout(let s): return "源文件结构不符合预期：\(s)"
            case .pixelCountMismatch(let e, let n): return "像素数不符：期望 \(e)，收到 \(n)"
            }
        }
    }

    /// Tags that describe the byte layout of the pixels. Everything else is preserved.
    static let layoutTags: Set<UInt16> = [
        254, 256, 257, 258, 259, 262, 273, 277, 278, 279, 284, 317, 339,
        322, 323, 324, 325, 330, 34665, 34853,
    ]

    public struct TileGrid: Sendable, Equatable {
        public var tileWidth: Int
        public var tileHeight: Int
        public init(tileWidth: Int = 256, tileHeight: Int = 256) {
            self.tileWidth = tileWidth
            self.tileHeight = tileHeight
        }
    }

    /// One image's worth of samples.
    ///
    /// `label` becomes that page's `270 ImageDescription` (e.g.
    /// `"denoised alternate: nlmf-denoise strength=1.0"`). For the primary layer it is optional: when
    /// `nil` the source's own description is carried over.
    public struct Layer: Sendable {
        public var samples: [UInt16]
        public var label: String?
        public init(samples: [UInt16], label: String? = nil) {
            self.samples = samples
            self.label = label
        }
    }

    public struct Result: Sendable {
        public let byteCount: Int
        public let tileCount: Int
        public let sampledTiles: Int
        public let compressedFraction: Double
        /// Whether an alternate (e.g. denoised) raw image was written as `SubIFDs[1]`.
        public let hasAlternate: Bool
        /// Compressed bytes in the alternate image's tiles; `0` when there is no alternate.
        public let alternateByteCount: Int
        public let alternateTileCount: Int

        init(byteCount: Int, tileCount: Int, sampledTiles: Int, compressedFraction: Double,
             hasAlternate: Bool = false, alternateByteCount: Int = 0,
             alternateTileCount: Int = 0) {
            self.byteCount = byteCount
            self.tileCount = tileCount
            self.sampledTiles = sampledTiles
            self.compressedFraction = compressedFraction
            self.hasAlternate = hasAlternate
            self.alternateByteCount = alternateByteCount
            self.alternateTileCount = alternateTileCount
        }
    }

    /// Single-image convenience: rewrites `source` with the given sample values.
    ///
    /// Kept because it is the shape existing call sites and acceptance scripts use. It is exactly
    /// `write(primary:alternate:nil:)`, byte for byte.
    ///
    /// - Parameters:
    ///   - samples: row-major mosaic, `width * height` entries, same CFA order as the source.
    ///   - grid: tile geometry. 256×256 matches what Adobe and Leica emit for this sensor.
    ///   - tableSampleTiles: how many tiles feed the Huffman statistics. 12 is plenty: the tables
    ///     only need the *shape* of the difference histogram, and more tiles cost time without
    ///     measurably shrinking the file.
    public static func write(
        samples: [UInt16],
        width: Int, height: Int,
        from source: URL,
        to destination: URL,
        grid: TileGrid = TileGrid(),
        tableSampleTiles: Int = 12
    ) throws -> Result {
        try write(primary: Layer(samples: samples), alternate: nil,
                  width: width, height: height,
                  from: source, to: destination,
                  grid: grid, tableSampleTiles: tableSampleTiles)
    }

    /// Rewrites `source` with the primary sample values, optionally keeping a second full-resolution
    /// mosaic as `SubIFDs[1]`.
    ///
    /// - Parameters:
    ///   - primary: the mosaic that becomes `SubIFDs[0]` — the one a standard reader decodes.
    ///   - alternate: a second mosaic at the same geometry, written at `SubIFDs[1]`. `nil` produces
    ///     the single-image file the convenience overload produces.
    ///   - grid/tableSampleTiles: applied to both layers; each gets its own Huffman tables built
    ///     from its own first `tableSampleTiles` tiles (a denoised mosaic has a different
    ///     difference histogram than a noisy one, so sharing the tables would cost bytes).
    public static func write(
        primary: Layer,
        alternate: Layer?,
        width: Int, height: Int,
        from source: URL,
        to destination: URL,
        grid: TileGrid = TileGrid(),
        tableSampleTiles: Int = 12
    ) throws -> Result {
        guard primary.samples.count == width * height else {
            throw WriteError.pixelCountMismatch(expected: width * height, got: primary.samples.count)
        }
        if let alternate = alternate, alternate.samples.count != width * height {
            throw WriteError.pixelCountMismatch(expected: width * height, got: alternate.samples.count)
        }

        let source = try SourceDNG(url: source)

        let encodedPrimary = encodeTiles(primary.samples, width: width, height: height,
                                         grid: grid, tableSampleTiles: tableSampleTiles)
        let encodedAlternate = alternate.map {
            encodeTiles($0.samples, width: width, height: height,
                        grid: grid, tableSampleTiles: tableSampleTiles)
        }
        let fraction = Double(encodedPrimary.compressedBytes) / Double(primary.samples.count * 2)

        // Everything in the source that describes the picture rather than the bytes of one page.
        var preserved = source.ifd0.filter { !layoutTags.contains($0.key) }
        for (tag, value) in source.raw where !layoutTags.contains(tag) {
            preserved[tag] = value          // the RAW's metadata wins over IFD0's
        }

        if let encodedAlternate = encodedAlternate {
            return try assembleDual(original: encodedPrimary, alternate: encodedAlternate,
                                    preserved: preserved, source: source,
                                    originalLabel: primary.label, alternateLabel: alternate?.label,
                                    width: width, height: height, grid: grid,
                                    fraction: fraction, to: destination)
        }
        return try assembleSingle(encoded: encodedPrimary, preserved: preserved, source: source,
                                  width: width, height: height, grid: grid,
                                  fraction: fraction, to: destination)
    }

    // MARK: - single-image assembly

    /// The pre-existing layout, unchanged: `header | IFD0 (raw) | IFD1 (preview) | EXIF | GPS |
    /// tiles | preview strips`. IFD0's next-IFD pointer is the preview, so a viewer that only walks
    /// the chain finds it.
    private static func assembleSingle(encoded: EncodedPixels, preserved: [UInt16: TIFFEntry],
                                       source: SourceDNG, width: Int, height: Int,
                                       grid: TileGrid, fraction: Double,
                                       to destination: URL) throws -> Result {
        var entries = preserved
        func put(_ tag: UInt16, _ type: UInt16, _ count: Int, _ payload: [UInt8]) {
            entries[tag] = TIFFEntry(type: type, count: count, value: payload)
        }
        put(254, 4, 1, u32(0))                              // NewSubfileType: primary image
        put(256, 4, 1, u32(UInt32(width)))
        put(257, 4, 1, u32(UInt32(height)))
        put(258, 3, 1, u16(16))                             // BitsPerSample
        put(259, 3, 1, u16(7))                              // Compression: lossless JPEG
        put(262, 3, 1, u16(32803))                          // Photometric: CFA
        put(277, 3, 1, u16(1))                              // SamplesPerPixel
        put(284, 3, 1, u16(1))                              // PlanarConfiguration: chunky
        put(339, 3, 1, u16(1))                              // SampleFormat: unsigned
        put(322, 4, 1, u32(UInt32(grid.tileWidth)))
        put(323, 4, 1, u32(UInt32(grid.tileHeight)))
        put(324, 4, encoded.tileCount,
            [UInt8](repeating: 0, count: 4 * encoded.tileCount))   // filled below
        put(325, 4, encoded.tileCount, encoded.blobs.flatMap { u32(UInt32($0.count)) })
        if source.exif != nil { put(34665, 4, 1, u32(0)) }
        if source.gps != nil { put(34853, 4, 1, u32(0)) }

        // IFD1 = the source's preview page, verbatim except its strip offsets/counts.
        var previewEntries: [UInt16: TIFFEntry] = [:]
        if let preview = source.preview {
            previewEntries = preview.entries.filter {
                ![273, 279, 330, 34665, 34853].contains($0.key)
            }
            previewEntries[254] = TIFFEntry(type: 4, count: 1, value: u32(1))
            previewEntries[273] = TIFFEntry(type: 4, count: preview.chunks.count,
                                            value: [UInt8](repeating: 0, count: 4 * preview.chunks.count))
            previewEntries[279] = TIFFEntry(type: 4, count: preview.chunks.count,
                                            value: preview.chunks.flatMap { u32(UInt32($0.count)) })
        }

        // Layout: header | IFD0 | payload0 | IFD1 | payload1 | EXIF | payloadE | GPS | payloadG |
        //         tiles | preview data
        let ifd0 = entries.sorted { $0.key < $1.key }.map { (tag: $0.key, entry: $0.value) }
        let ifd1 = previewEntries.sorted { $0.key < $1.key }.map { (tag: $0.key, entry: $0.value) }
        let exif = (source.exif ?? [:]).sorted { $0.key < $1.key }.map { (tag: $0.key, entry: $0.value) }
        let gps = (source.gps ?? [:]).sorted { $0.key < $1.key }.map { (tag: $0.key, entry: $0.value) }

        let size0 = IFDLayout(headSize: 2 + 12 * ifd0.count + 4, payloadSize: payloadSize(ifd0))
        let size1 = IFDLayout(headSize: ifd1.isEmpty ? 0 : 2 + 12 * ifd1.count + 4,
                              payloadSize: payloadSize(ifd1))
        let sizeE = IFDLayout(headSize: exif.isEmpty ? 0 : 2 + 12 * exif.count + 4,
                              payloadSize: payloadSize(exif))
        let sizeG = IFDLayout(headSize: gps.isEmpty ? 0 : 2 + 12 * gps.count + 4,
                              payloadSize: payloadSize(gps))

        let offIFD1 = 8 + size0.total
        let offEXIF = offIFD1 + size1.total
        let offGPS = offEXIF + sizeE.total
        var offTiles = offGPS + sizeG.total
        offTiles += (4 - offTiles % 4) % 4

        let tileOffsets = placeBlobs(encoded.blobs, from: offTiles)
        let previewOffsets = placeBlobs(source.preview?.chunks ?? [],
                                        from: tileOffsets.last.map {
                                            Int($0) + encoded.blobs[encoded.blobs.count - 1].count
                                                + ((4 - encoded.blobs[encoded.blobs.count - 1].count % 4) % 4)
                                        } ?? offTiles)

        // Back-fill the pointers that depend on the layout.
        var final0 = setEntry(ifd0, tag: 324, value: tileOffsets.flatMap { u32($0) })
        if source.exif != nil { final0 = setEntry(final0, tag: 34665, value: u32(UInt32(offEXIF))) }
        if source.gps != nil { final0 = setEntry(final0, tag: 34853, value: u32(UInt32(offGPS))) }
        var final1 = ifd1
        if !final1.isEmpty {
            final1 = setEntry(final1, tag: 273, value: previewOffsets.flatMap { u32($0) })
        }

        var out = Data()
        emitHeader(&out)
        // No padding between IFDs: every later offset is computed from head+payload sizes, so an
        // extra pad here shifts everything by 4 (this had the tiles 4 bytes out of place, which the
        // offset assertion in `appendBlobs` then caught).
        //
        // IFD0's "next IFD" pointer must point at IFD1 when there is one — leaving it 0 is how the
        // preview went missing: the preview page was written but nothing could reach it.
        appendIFD(&out, final0, payloadOffset: 8 + size0.headSize,
                  nextIFD: final1.isEmpty ? 0 : UInt32(offIFD1))
        if !final1.isEmpty {
            appendIFD(&out, final1, payloadOffset: offIFD1 + size1.headSize)
        }
        if !exif.isEmpty {
            appendIFD(&out, exif, payloadOffset: offEXIF + sizeE.headSize)
        }
        if !gps.isEmpty {
            appendIFD(&out, gps, payloadOffset: offGPS + sizeG.headSize)
        }
        while out.count < offTiles { out.append(0) }
        try appendBlobs(&out, encoded.blobs, offsets: tileOffsets, "primary")
        for chunk in source.preview?.chunks ?? [] {
            out.append(contentsOf: chunk)
            pad4(&out)
        }

        try out.write(to: destination)
        return Result(byteCount: out.count, tileCount: encoded.tileCount,
                      sampledTiles: encoded.sampledTiles, compressedFraction: fraction)
    }

    // MARK: - dual-image assembly

    /// The camera-shaped layout: **IFD0 is the preview**, and both raws hang off `330 SubIFDs`, the
    /// original first.
    ///
    /// `ImageIO`/`CIRAWFilter` decode the first `NewSubfileType = 0` raw in `SubIFDs` and fall back to
    /// IFD0 only when there is none, so `SubIFDs[0]` decides what "the picture" is for every standard
    /// reader. Keeping the original there makes the dual file safe to hand to anything.
    private static func assembleDual(original: EncodedPixels, alternate: EncodedPixels,
                                     preserved: [UInt16: TIFFEntry], source: SourceDNG,
                                     originalLabel: String?, alternateLabel: String?,
                                     width: Int, height: Int, grid: TileGrid,
                                     fraction: Double, to destination: URL) throws -> Result {
        guard let preview = source.preview else {
            throw WriteError.unexpectedLayout(
                "双 raw 输出需要源文件自带预览页：IFD0 要放预览，两组 raw 才能都放进 SubIFDs")
        }

        // IFD0 = the preview page. It starts from the source's global metadata — colour matrices,
        // AsShotNeutral, black/white levels — because readers take those from IFD0 whichever page
        // they decode, then adds the preview's own pixel tags, which no other page describes.
        var page0 = preserved
        for (tag, value) in preview.entries where page0[tag] == nil { page0[tag] = value }
        // A tiled preview cannot be copied: its tile offsets point into the source file.
        // `SourceDNG.preview` only ever comes from strips, so this is belt and braces.
        for tag: UInt16 in [322, 323, 324, 325] { page0[tag] = nil }
        // CFA descriptors belong to the raw pages; on an RGB preview they contradict tag 262.
        for tag: UInt16 in [33421, 33422] { page0[tag] = nil }
        page0[254] = TIFFEntry(type: 4, count: 1, value: u32(1))   // reduced-resolution preview
        page0[273] = TIFFEntry(type: 4, count: preview.chunks.count,
                               value: [UInt8](repeating: 0, count: 4 * preview.chunks.count))
        page0[279] = TIFFEntry(type: 4, count: preview.chunks.count,
                               value: preview.chunks.flatMap { u32(UInt32($0.count)) })
        page0[330] = TIFFEntry(type: 4, count: 2,
                               value: [UInt8](repeating: 0, count: 8))   // filled below
        if source.exif != nil { page0[34665] = TIFFEntry(type: 4, count: 1, value: u32(0)) }
        if source.gps != nil { page0[34853] = TIFFEntry(type: 4, count: 1, value: u32(0)) }

        // The two raw pages: each describes itself completely — pixel tags plus the source raw's
        // CFA / level / crop / opcode tags — because a SubIFD cannot rely on the preview page above
        // it for anything a decoder needs to turn bytes into samples.
        var originalPage = rawPage(encoded: original, source: source, label: originalLabel,
                                   subfiletype: 0, width: width, height: height, grid: grid)
        var alternatePage = rawPage(encoded: alternate, source: source, label: alternateLabel,
                                    subfiletype: 1, width: width, height: height, grid: grid)
        if alternatePage[270] == nil { alternatePage[270] = asciiEntry("denoised alternate") }
        originalPage[330] = nil                       // rawPage copies nothing that could nest

        // Layout: header | IFD0 (preview) | payload0 | raw IFD (original) | payload |
        //         raw IFD (alternate) | payload | EXIF | GPS | original tiles | alternate tiles |
        //         preview strips
        let ifd0 = page0.sorted { $0.key < $1.key }.map { (tag: $0.key, entry: $0.value) }
        let ifdOriginal = originalPage.sorted { $0.key < $1.key }.map { (tag: $0.key, entry: $0.value) }
        let ifdAlternate = alternatePage.sorted { $0.key < $1.key }.map { (tag: $0.key, entry: $0.value) }
        let exif = (source.exif ?? [:]).sorted { $0.key < $1.key }.map { (tag: $0.key, entry: $0.value) }
        let gps = (source.gps ?? [:]).sorted { $0.key < $1.key }.map { (tag: $0.key, entry: $0.value) }

        let size0 = IFDLayout(headSize: 2 + 12 * ifd0.count + 4, payloadSize: payloadSize(ifd0))
        let sizeO = IFDLayout(headSize: 2 + 12 * ifdOriginal.count + 4,
                              payloadSize: payloadSize(ifdOriginal))
        let sizeA = IFDLayout(headSize: 2 + 12 * ifdAlternate.count + 4,
                              payloadSize: payloadSize(ifdAlternate))
        let sizeE = IFDLayout(headSize: exif.isEmpty ? 0 : 2 + 12 * exif.count + 4,
                              payloadSize: payloadSize(exif))
        let sizeG = IFDLayout(headSize: gps.isEmpty ? 0 : 2 + 12 * gps.count + 4,
                              payloadSize: payloadSize(gps))

        let offOriginal = 8 + size0.total
        let offAlternate = offOriginal + sizeO.total
        let offEXIF = offAlternate + sizeA.total
        let offGPS = offEXIF + sizeE.total
        var offTiles = offGPS + sizeG.total
        offTiles += (4 - offTiles % 4) % 4

        let originalTileOffsets = placeBlobs(original.blobs, from: offTiles)
        let alternateTileOffsets = placeBlobs(
            alternate.blobs,
            from: originalTileOffsets.last.map {
                Int($0) + original.blobs[original.blobs.count - 1].count
                    + ((4 - original.blobs[original.blobs.count - 1].count % 4) % 4)
            } ?? offTiles)
        let previewOffsets = placeBlobs(
            preview.chunks,
            from: alternateTileOffsets.last.map {
                Int($0) + alternate.blobs[alternate.blobs.count - 1].count
                    + ((4 - alternate.blobs[alternate.blobs.count - 1].count % 4) % 4)
            } ?? offTiles)

        // Back-fill the pointers that depend on the layout.
        var final0 = setEntry(ifd0, tag: 273, value: previewOffsets.flatMap { u32($0) })
        final0 = setEntry(final0, tag: 330,
                          value: u32(UInt32(offOriginal)) + u32(UInt32(offAlternate)))
        if source.exif != nil { final0 = setEntry(final0, tag: 34665, value: u32(UInt32(offEXIF))) }
        if source.gps != nil { final0 = setEntry(final0, tag: 34853, value: u32(UInt32(offGPS))) }
        let finalOriginal = setEntry(ifdOriginal, tag: 324,
                                     value: originalTileOffsets.flatMap { u32($0) })
        let finalAlternate = setEntry(ifdAlternate, tag: 324,
                                      value: alternateTileOffsets.flatMap { u32($0) })

        var out = Data()
        emitHeader(&out)
        // IFD0's next-IFD pointer stays 0: the raw pages are SubIFDs, reachable through tag 330 and
        // deliberately not through the chain — that is the camera shape, and it is what makes a
        // reader that honours 330 pick the raw while a reader that ignores it falls back to the
        // preview instead of to a raw it did not expect.
        appendIFD(&out, final0, payloadOffset: 8 + size0.headSize, nextIFD: 0)
        appendIFD(&out, finalOriginal, payloadOffset: offOriginal + sizeO.headSize)
        appendIFD(&out, finalAlternate, payloadOffset: offAlternate + sizeA.headSize)
        if !exif.isEmpty {
            appendIFD(&out, exif, payloadOffset: offEXIF + sizeE.headSize)
        }
        if !gps.isEmpty {
            appendIFD(&out, gps, payloadOffset: offGPS + sizeG.headSize)
        }
        while out.count < offTiles { out.append(0) }
        try appendBlobs(&out, original.blobs, offsets: originalTileOffsets, "original")
        try appendBlobs(&out, alternate.blobs, offsets: alternateTileOffsets, "alternate")
        for chunk in preview.chunks {
            out.append(contentsOf: chunk)
            pad4(&out)
        }

        try out.write(to: destination)
        return Result(byteCount: out.count,
                      tileCount: original.tileCount,
                      sampledTiles: original.sampledTiles,
                      compressedFraction: fraction,
                      hasAlternate: true,
                      alternateByteCount: alternate.compressedBytes,
                      alternateTileCount: alternate.tileCount)
    }

    /// One raw page: the source raw's metadata (minus everything that describes an old byte layout,
    /// minus the file-global XMP) with this writer's pixel tags on top.
    ///
    /// `subfiletype` is `0` for the page a reader should decode and `1` for the alternate — see the
    /// type's documentation for the measurement behind that.
    static func rawPage(encoded: EncodedPixels, source: SourceDNG, label: String?,
                        subfiletype: UInt32, width: Int, height: Int,
                        grid: TileGrid) -> [UInt16: TIFFEntry] {
        var page = source.raw.filter { !layoutTags.contains($0.key) && $0.key != 700 }
        func put(_ tag: UInt16, _ type: UInt16, _ count: Int, _ payload: [UInt8]) {
            page[tag] = TIFFEntry(type: type, count: count, value: payload)
        }
        put(254, 4, 1, u32(subfiletype))
        put(256, 4, 1, u32(UInt32(width)))
        put(257, 4, 1, u32(UInt32(height)))
        put(258, 3, 1, u16(16))
        put(259, 3, 1, u16(7))                              // lossless JPEG
        put(262, 3, 1, u16(32803))                          // CFA
        put(277, 3, 1, u16(1))
        put(284, 3, 1, u16(1))
        put(339, 3, 1, u16(1))
        put(322, 4, 1, u32(UInt32(grid.tileWidth)))
        put(323, 4, 1, u32(UInt32(grid.tileHeight)))
        put(324, 4, encoded.tileCount, [UInt8](repeating: 0, count: 4 * encoded.tileCount))
        put(325, 4, encoded.tileCount, encoded.blobs.flatMap { u32(UInt32($0.count)) })
        if let label = label { page[270] = asciiEntry(label) }
        return page
    }

    /// TIFF ASCII is 7-bit and NUL-terminated, and `count` includes the terminator; a label with
    /// anything above U+007F is folded to '_' rather than written as invalid ASCII.
    static func asciiEntry(_ text: String) -> TIFFEntry {
        let bytes = text.utf8.map { $0 < 0x80 ? $0 : 0x5F } + [0]
        return TIFFEntry(type: 2, count: bytes.count, value: bytes)
    }

    // MARK: - tiling + encoding

    struct EncodedPixels {
        var blobs: [[UInt8]]
        var compressedBytes: Int
        var sampledTiles: Int
        var tileCount: Int { blobs.count }
    }

    /// Tiles a mosaic and lossless-JPEG encodes every tile, building the Huffman tables from the
    /// first `tableSampleTiles` tiles of *this* mosaic.
    static func encodeTiles(_ samples: [UInt16], width: Int, height: Int,
                            grid: TileGrid, tableSampleTiles: Int) -> EncodedPixels {
        // 1. Tile the mosaic. Edge tiles are padded by repeating the last row/column: the decoder
        //    crops them away with ActiveArea/DefaultCrop, so their contents never reach the picture,
        //    and repeating (rather than zero filling) keeps the difference histogram representative.
        let nx = (width + grid.tileWidth - 1) / grid.tileWidth
        let ny = (height + grid.tileHeight - 1) / grid.tileHeight
        var tiles: [[UInt16]] = []
        tiles.reserveCapacity(nx * ny)
        samples.withUnsafeBufferPointer { src in
            for ty in 0..<ny {
                for tx in 0..<nx {
                    var tile = [UInt16](repeating: 0, count: grid.tileWidth * grid.tileHeight)
                    tile.withUnsafeMutableBufferPointer { dst in
                        for y in 0..<grid.tileHeight {
                            let sy = min(ty * grid.tileHeight + y, height - 1)
                            let srcRow = sy * width
                            let dstRow = y * grid.tileWidth
                            for x in 0..<grid.tileWidth {
                                let sx = min(tx * grid.tileWidth + x, width - 1)
                                dst[dstRow + x] = src[srcRow + sx]
                            }
                        }
                    }
                    tiles.append(tile)
                }
            }
        }

        // 2. Huffman tables from a sample of the tiles, then encode every tile.
        let sampled = Array(tiles.prefix(max(1, tableSampleTiles)))
        let tables = RawLosslessJPEG.buildTables(
            sampled, width: grid.tileWidth, height: grid.tileHeight, components: 2)

        var blobs: [[UInt8]] = []
        blobs.reserveCapacity(tiles.count)
        for tile in tiles {
            blobs.append(tile.withUnsafeBufferPointer {
                RawLosslessJPEG.encode($0, width: grid.tileWidth, height: grid.tileHeight,
                                       components: 2, tables: tables)
            })
        }
        let compressedBytes = blobs.reduce(0) { $0 + $1.count }
        return EncodedPixels(blobs: blobs, compressedBytes: compressedBytes,
                             sampledTiles: sampled.count)
    }

    // MARK: - little helpers

    static func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    static func u32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    static func pad4(_ out: inout Data) {
        while out.count % 4 != 0 { out.append(0) }
    }

    struct IFDLayout { let headSize: Int; let payloadSize: Int; var total: Int { headSize + payloadSize } }

    static func payloadSize(_ entries: [(tag: UInt16, entry: TIFFEntry)]) -> Int {
        var total = 0
        for e in entries where e.entry.value.count > 4 {
            total += e.entry.value.count
            if total % 2 != 0 { total += 1 }
        }
        return total
    }

    static func setEntry(_ entries: [(tag: UInt16, entry: TIFFEntry)],
                         tag: UInt16, value: [UInt8]) -> [(tag: UInt16, entry: TIFFEntry)] {
        entries.map { e in
            e.tag == tag ? (tag: tag, entry: TIFFEntry(type: e.entry.type,
                                                       count: e.entry.count, value: value)) : e
        }
    }

    /// Byte offset of every blob, packed back to back on a 4-byte boundary, starting at `start`.
    static func placeBlobs(_ blobs: [[UInt8]], from start: Int) -> [UInt32] {
        var offsets: [UInt32] = []
        var cursor = start
        for blob in blobs {
            offsets.append(UInt32(cursor))
            cursor += blob.count
            cursor += (4 - cursor % 4) % 4
        }
        return offsets
    }

    /// Refuses to write a tile anywhere but the offset its IFD advertised. A silent mismatch here is
    /// the failure mode that produces a file which opens but shows noise, so it is an error.
    static func appendBlobs(_ out: inout Data, _ blobs: [[UInt8]], offsets: [UInt32],
                            _ what: String) throws {
        for (i, blob) in blobs.enumerated() {
            guard out.count == Int(offsets[i]) else {
                throw WriteError.unexpectedLayout(
                    "\(what) 瓦片 \(i) 偏移 \(out.count) ≠ 表内 \(offsets[i])")
            }
            out.append(contentsOf: blob)
            pad4(&out)
        }
    }

    static func emitHeader(_ out: inout Data) {
        out.append(contentsOf: [0x49, 0x49])                 // "II"
        out.append(contentsOf: u16(42))
        out.append(contentsOf: u32(8))                       // IFD0 at byte 8
    }

    static func appendIFD(_ out: inout Data, _ entries: [(tag: UInt16, entry: TIFFEntry)],
                          payloadOffset: Int, nextIFD: UInt32 = 0) {
        out.append(contentsOf: u16(UInt16(entries.count)))
        var payload = Data()
        for e in entries {
            out.append(contentsOf: u16(e.tag))
            out.append(contentsOf: u16(e.entry.type))
            out.append(contentsOf: u32(UInt32(e.entry.count)))
            if e.entry.value.count <= 4 {
                var inline = e.entry.value
                while inline.count < 4 { inline.append(0) }
                out.append(contentsOf: inline)
            } else {
                out.append(contentsOf: u32(UInt32(payloadOffset + payload.count)))
                payload.append(contentsOf: e.entry.value)
                if payload.count % 2 != 0 { payload.append(0) }
            }
        }
        out.append(contentsOf: u32(nextIFD))          // link to the next IFD (0 = last)
        out.append(payload)
    }
}
