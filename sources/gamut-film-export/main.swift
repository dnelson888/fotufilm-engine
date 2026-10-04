// gamut-film-export — writes each film's prepared kernel inputs (the same "FSWP" pack the browser
// engine renders from: configuration, spectral exposure table, film and paper output tables) for
// Gamut to read. Added in Gamut's fork; not part of Fotufilm. Apache-2.0, as the engine it calls.
//
//   gamut-film-export <output-dir> [width height]
//
// Grain, halation and the other spatial effects are left in the pack as the stock defines them;
// Gamut uses only the per-pixel tables and supplies its own grain.
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
        manifest.append(["name": job.name, "stock": job.stock, "push": job.push,
                         "exposureEV": job.exposureEV, "width": width, "height": height,
                         "bytes": pack.count])
        print("Wrote \(job.name): \(pack.count) bytes")
    } catch {
        print("FAILED \(job.name): \(error)")
        manifest.append(["name": job.name, "error": String(describing: error)])
    }
}
let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
try json.write(to: output.appendingPathComponent("manifest.json"))
print("Done: \(manifest.count) entries in \(output.path)")
