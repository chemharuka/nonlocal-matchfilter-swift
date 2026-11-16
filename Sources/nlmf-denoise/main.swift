//
//  main.swift — nlmf-denoise
//
//  RawNIND raw->raw denoising on Core ML, DNG in and DNG out.
//
//  usage: nlmf-denoise <model.mlpackage> <in.dng> --out <out.dng>
//                      [--a r,g,b,g2] [--b r,g,b,g2] [--strength S] [--json]
//

import Foundation
import NonlocalMatchFilter

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    die("usage: nlmf-denoise <model.mlpackage> <in.dng> --out <out.dng> "
        + "[--a r,g,b,g2] [--b r,g,b,g2] [--strength S] [--json]")
}

func flag(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func parseDoubles(_ s: String) -> [Double] {
    s.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
}

let mlpackage = args[0]
let inputPath = args[1]
guard let outPath = flag("--out") else { die("missing --out") }

// Defaults are the ones the reference tool ships for a full-frame sensor; the
// pairs are per CFA channel in the model's R, G, B, G order.
let a = flag("--a").map(parseDoubles) ?? [0.0004, 0.0003, 0.0004, 0.0003]
let b = flag("--b").map(parseDoubles) ?? [3e-6, 1e-6, 1e-6, 1e-6]
guard a.count == 4, b.count == 4 else { die("--a and --b each need 4 values (R,G,B,G)") }

let strength = flag("--strength").flatMap(Double.init) ?? 1.0
let crop = flag("--crop").flatMap(Int.init) ?? 0
// `--measure-noise` estimates the sensor's Poisson-Gaussian curve from this
// frame and ignores --a/--b. Without it, or with explicit values, the CLI
// defaults below are used.
let measureNoise = args.contains("--measure-noise")
// With --measure-noise, --noise-sample=checkerboard halves the blocks it reads.
let checkerboardNoise = flag("--noise-sample").map { $0 == "checkerboard" } ?? false
let asJSON = args.contains("--json")

let request = DenoiseRequest(
    input: URL(fileURLWithPath: inputPath),
    output: URL(fileURLWithPath: outPath),
    mlpackage: mlpackage,
    a: a, b: b, strength: strength, crop: crop,
    estimateNoise: measureNoise, checkerboardNoise: checkerboardNoise)

do {
    let report = try DenoisePipeline.run(request) { line in
        if !asJSON { FileHandle.standardError.write(Data((line + "\n").utf8)) }
    }
    if asJSON {
        let obj: [String: Any] = [
            "width": report.width,
            "height": report.height,
            "cfa": report.cfa,
            "blackMean": report.blackMean,
            "white": report.white,
            "tiles": report.tiles,
            "tilesX": report.tilesX,
            "tilesY": report.tilesY,
            "readSeconds": report.readSeconds,
            "inferenceSeconds": report.inferenceSeconds,
            "writeSeconds": report.writeSeconds,
            "seconds": report.seconds,
            "outputBytes": report.outputBytes,
            "writerTiles": report.writerTiles,
        ]
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } else {
        print("wrote \(outPath)  \(report.width)×\(report.height) \(report.cfa)")
        print(String(format: "  read %.1f s, inference %.1f s, write %.1f s, total %.1f s",
                     report.readSeconds, report.inferenceSeconds,
                     report.writeSeconds, report.seconds))
        print("  \(report.tiles) tiles (\(report.tilesX)×\(report.tilesY)), "
              + "\(report.outputBytes / 1_000_000) MB")
    }
} catch {
    die("error: \(error)")
}
