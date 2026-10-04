// gamut-film-export — writes each film's prepared kernel inputs (the same "FSWP" pack the browser
// engine renders from: configuration, spectral exposure table, film and paper output tables) for
// Gamut to read. Added in Gamut's fork; not part of Fotufilm. Apache-2.0, as the engine it calls.
//
//   gamut-film-export <output-dir> [width height]
//
// Grain, halation and the other spatial effects are left in the pack as the stock defines them,
// and their settings are also written at a ladder of widths (`<name>.w<width>.cfg`) for Gamut's
// own grain and halation, which render at every size.
import Foundation
import FotufilmCore

let arguments = CommandLine.arguments
let output = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "gamut-packs", isDirectory: true)
let width = arguments.count > 3 ? (Int(arguments[2]) ?? 2000) : 2000
let height = arguments.count > 3 ? (Int(arguments[3]) ?? 1333) : 1333
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

struct Job { let name: String; let stock: String; let push: Float; let exposureEV: Float }

// The films Gamut's film looks are built on, at box speed, plus their variants.
let films = ["portra400", "gold200", "ultramax400", "pro400h", "ektar100", "cinestill800t",
             "provia100f", "kodachrome64", "trix400", "hp5plus400"]
var jobs = films.map { Job(name: $0, stock: $0, push: 0, exposureEV: 0) }
jobs += [
    Job(name: "portra400-over1", stock: "portra400", push: 0, exposureEV: 1),
    Job(name: "cinestill800t-push1", stock: "cinestill800t", push: 1, exposureEV: -1),
    Job(name: "cinestill800t-push2", stock: "cinestill800t", push: 2, exposureEV: -2),
    Job(name: "ektar100-push2", stock: "ektar100", push: 2, exposureEV: -2),
]

print("Stocks available: \(FilmStock.allPresetIDs.joined(separator: ", "))")
var manifest: [[String: Any]] = []
for job in jobs {
    guard let stock = FilmStock.named(job.stock) else {
        print("SKIPPED \(job.name): no stock '\(job.stock)'")
        manifest.append(["name": job.name, "error": "unknown stock"])
        continue
    }
    var options = FotufilmEngine.Options()
    options.format = FilmFormat.native(forStockID: job.stock)
    options.developmentEV = job.push
    options.exposureEV = job.exposureEV
    do {
        let pack = try WebFilmProfile.prepare(stock: stock, options: options, width: width, height: height)
        try pack.write(to: output.appendingPathComponent("\(job.name).fswp"))
        // AUTO LEVELS (Gamut, 4 October): the per-photograph receiver levels the web editor's
        // "Screen · Auto Levels" applies (web/src/screen-conversion.js, `applyScreenLevels`),
        // tabulated exactly as WebStockCatalogue tabulates them for the browser: each sample the
        // scale and shift against the levels the pack was prepared with, over the scene's metered
        // highlight from -12 to 12 stops; `reads` for the films whose records Auto Levels
        // balances; `placesFilm` for the ones it gives film exposure and tone.
        var meterWritten = false
        if !stock.isReflectionPrint {
            let style = DigitalReferenceStyle.autoLevels
            let fixed = style.receiverLevels(for: stock)
            let stops = (0...512).map { -12 + Float($0) * 24 / 512 }
            var meter: [String: Any] = [
                "min": -12.0, "max": 12.0,
                "adjustments": stops.map { s -> [Float] in
                    let levels = style.receiverLevels(for: stock, sceneHighlightStops: s)
                    return [levels.scale / fixed.scale, levels.shift - fixed.shift]
                },
            ]
            if !stock.isReversal { meter["placesFilm"] = true }
            if DigitalReferenceStyle.autoLevelsColourRead(for: stock, stops: 0) != nil {
                meter["reads"] = stops.map { DigitalReferenceStyle.autoLevelsColourRead(for: stock, stops: $0)! }
            }
            let json = try JSONSerialization.data(withJSONObject: meter, options: [.sortedKeys])
            try json.write(to: output.appendingPathComponent("\(job.name).meter.json"))
            meterWritten = true
        }
        // GRAIN AT EVERY SIZE (Gamut, 4 October): the grain and halation settings are worked
        // out for the width a pack is prepared at (clumps per pixel, clump sigma, amplitude
        // through the 48 µm aperture, halation radii — all from the pixel pitch on the frame).
        // Gamut renders at many sizes, so the configuration alone (header included, no tables)
        // is written at a ladder of widths: `<name>.w<width>.cfg`, 3:2.
        for ladderWidth in [500, 1000, 2000, 4000, 8000] {
            let ladderPack = try WebFilmProfile.prepare(stock: stock, options: options,
                                                        width: ladderWidth, height: ladderWidth * 2 / 3)
            // FSWP v2: "FSWP", then nine Int32s (the configuration's count at byte 24), then it.
            let count = ladderPack.subdata(in: 24..<28).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
            let end = min(ladderPack.count, 40 + Int(Int32(littleEndian: count)) * 4)
            try ladderPack.subdata(in: 0..<end)
                .write(to: output.appendingPathComponent("\(job.name).w\(ladderWidth).cfg"))
        }
        manifest.append(["name": job.name, "stock": job.stock, "push": job.push,
                         "exposureEV": job.exposureEV, "width": width, "height": height,
                         "bytes": pack.count, "meter": meterWritten])
        print("Wrote \(job.name): \(pack.count) bytes")
    } catch {
        print("FAILED \(job.name): \(error)")
        manifest.append(["name": job.name, "error": String(describing: error)])
    }
}
let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
try json.write(to: output.appendingPathComponent("manifest.json"))
print("Done: \(manifest.count) entries in \(output.path)")
