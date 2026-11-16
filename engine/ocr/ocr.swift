// ocr: prints the text recognised in an image (UTF-8, one line per text line) using the macOS Vision framework.
// Usage: ocr <image path> [comma-separated Vision language codes, e.g. sv-SE,en-US]
// Exit 0 with the text on stdout (empty if none); exit 1 with a message on stderr on failure.
import Foundation
import ImageIO
import Vision

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("ocr: \(message)\n".utf8))
    exit(code)
}

let args = CommandLine.arguments
guard args.count >= 2 && args.count <= 3 else { fail("usage: ocr <image> [languages]", code: 2) }
let path = args[1]
let wanted = args.count == 3
    ? args[2].split(separator: ",").map { String($0) }
    : ["sv-SE", "en-US"]  // Vision has no Finnish; Swedish covers ä, ö, å

guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
      CGImageSourceGetCount(source) > 0 else {
    fail("cannot read image: \(path)")
}
// Decode at most 3000 px on the long side: bounds memory for large photos, keeps screenshot text legible.
let thumbOptions: [CFString: Any] = [
    kCGImageSourceCreateThumbnailFromImageAlways: true,
    kCGImageSourceCreateThumbnailWithTransform: true,
    kCGImageSourceThumbnailMaxPixelSize: 3000,
]
guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
    fail("cannot decode image: \(path)")
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = true
let supported = Set((try? request.supportedRecognitionLanguages()) ?? [])
let languages = wanted.filter { supported.contains($0) }
if languages.isEmpty { fail("none of the requested languages are supported: \(wanted.joined(separator: ","))") }
request.recognitionLanguages = languages

do {
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
} catch {
    fail("recognition failed: \(error.localizedDescription)")
}
let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
print(lines.joined(separator: "\n"))
exit(0)
