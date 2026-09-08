import Foundation
import Photos
import AppKit
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

// photos-helper: a thin PhotoKit bridge for the photon-migrate project.
//
// Subcommands:
//   list                                    -> JSONL of every PHAsset's metadata to stdout
//   export <localIdentifier> [--edited]     -> streams the raw asset bytes to stdout,
//                                              chunk by chunk, with zero local disk usage
//
// Both subcommands block until Photos library authorization is granted (macOS will
// show the system permission prompt on first run).

func requestAuthorization() -> Bool {
    let sema = DispatchSemaphore(value: 0)
    var granted = false
    PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
        granted = (status == .authorized || status == .limited)
        sema.signal()
    }
    sema.wait()
    return granted
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

struct AssetRecord: Codable {
    let localIdentifier: String
    let mediaType: Int
    let mediaSubtypes: Int
    let creationDate: Double?
    let modificationDate: Double?
    let pixelWidth: Int
    let pixelHeight: Int
    let hasAdjustments: Bool
    let isFavorite: Bool
    let duration: Double
    let originalFilename: String?
    let resourceTypes: [Int]
}

func listAssets() {
    let options = PHFetchOptions()
    options.includeHiddenAssets = true
    let fetchResult = PHAsset.fetchAssets(with: options)

    let encoder = JSONEncoder()
    let stdout = FileHandle.standardOutput

    fetchResult.enumerateObjects { asset, _, _ in
        let resources = PHAssetResource.assetResources(for: asset)
        let record = AssetRecord(
            localIdentifier: asset.localIdentifier,
            mediaType: asset.mediaType.rawValue,
            mediaSubtypes: Int(asset.mediaSubtypes.rawValue),
            creationDate: asset.creationDate?.timeIntervalSince1970,
            modificationDate: asset.modificationDate?.timeIntervalSince1970,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            hasAdjustments: asset.hasAdjustments,
            isFavorite: asset.isFavorite,
            duration: asset.duration,
            originalFilename: resources.first?.originalFilename,
            resourceTypes: resources.map { $0.type.rawValue }
        )
        if let data = try? encoder.encode(record) {
            stdout.write(data)
            stdout.write("\n".data(using: .utf8)!)
        }
    }
}

func pickResource(for asset: PHAsset, edited: Bool) -> PHAssetResource? {
    let resources = PHAssetResource.assetResources(for: asset)

    let originalTypes: [PHAssetResourceType] = [.photo, .video, .audio]
    let editedTypes: [PHAssetResourceType] = [.fullSizePhoto, .fullSizeVideo]

    if edited {
        if let match = resources.first(where: { editedTypes.contains($0.type) }) {
            return match
        }
        // No edited rendering exists (asset has no adjustments) -- caller should
        // check hasAdjustments via `list` first and not request --edited here.
        return nil
    } else {
        return resources.first(where: { originalTypes.contains($0.type) }) ?? resources.first
    }
}

func exportAsset(localIdentifier: String, edited: Bool) {
    let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
    guard let asset = fetchResult.firstObject else {
        fail("asset not found: \(localIdentifier)")
    }

    guard let resource = pickResource(for: asset, edited: edited) else {
        fail("no \(edited ? "edited" : "original") resource available for \(localIdentifier)")
    }

    let sema = DispatchSemaphore(value: 0)
    let stdout = FileHandle.standardOutput
    var streamError: Error?

    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = true // pull from iCloud on demand if not cached locally

    PHAssetResourceManager.default().requestData(
        for: resource,
        options: options,
        dataReceivedHandler: { chunk in
            stdout.write(chunk)
        },
        completionHandler: { error in
            streamError = error
            sema.signal()
        }
    )

    sema.wait()
    if let error = streamError {
        fail("export failed: \(error.localizedDescription)")
    }
}

// MARK: - Thumbnails

// Limits taken from Proton's own Mac client (PDCore Constants.swift):
//   type 1 "default": max 512x512,   max 60KB
//   type 2 "photo":   max 1920x1920, max 1MB
struct ThumbnailSpec {
    let maxPixels: CGFloat
    let maxBytes: Int

    static func forType(_ type: Int) -> ThumbnailSpec? {
        switch type {
        case 1: return ThumbnailSpec(maxPixels: 512, maxBytes: 60 * 1024)
        case 2: return ThumbnailSpec(maxPixels: 1920, maxBytes: 1024 * 1024)
        default: return nil
        }
    }
}

/// Encodes to JPEG, stepping quality down until it fits the byte budget.
/// Proton rejects thumbnails over the limit, and a photo whose thumbnail is
/// rejected still uploads -- it just shows up with no preview.
func encodeJPEG(_ image: CGImage, maxBytes: Int) -> Data? {
    for quality in stride(from: 0.8, through: 0.3, by: -0.1) {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        if data.length <= maxBytes {
            return data as Data
        }
    }
    return nil
}

/// Extracts a still from a video. Videos have no image data to request, so
/// without this they upload with no preview at all and sit in the backfill
/// queue forever.
func videoThumbnail(asset: PHAsset, spec: ThumbnailSpec) -> CGImage? {
    let options = PHVideoRequestOptions()
    options.isNetworkAccessAllowed = true
    options.deliveryMode = .highQualityFormat

    let sema = DispatchSemaphore(value: 0)
    var videoAsset: AVAsset?
    PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
        videoAsset = avAsset
        sema.signal()
    }
    sema.wait()

    guard let videoAsset else { return nil }

    let generator = AVAssetImageGenerator(asset: videoAsset)
    generator.appliesPreferredTrackTransform = true // honour rotation
    generator.maximumSize = CGSize(width: spec.maxPixels, height: spec.maxPixels)
    generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
    generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

    // A second in first: the opening frame of a video is very often black.
    // Falling back to frame zero covers clips shorter than that.
    for seconds in [1.0, 0.0] {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        if let image = try? generator.copyCGImage(at: time, actualTime: nil) {
            return image
        }
    }
    return nil
}

func writeThumbnail(localIdentifier: String, edited: Bool, type: Int) {
    guard let spec = ThumbnailSpec.forType(type) else {
        fail("unsupported thumbnail type \(type) (expected 1 or 2)")
    }

    let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
    guard let asset = fetchResult.firstObject else {
        fail("asset not found: \(localIdentifier)")
    }

    if asset.mediaType == .video {
        guard let frame = videoThumbnail(asset: asset, spec: spec) else {
            fail("could not extract a video frame for \(localIdentifier)")
        }
        guard let jpeg = encodeJPEG(frame, maxBytes: spec.maxBytes) else {
            fail("could not fit video thumbnail for \(localIdentifier) under \(spec.maxBytes) bytes")
        }
        FileHandle.standardOutput.write(jpeg)
        return
    }

    let options = PHImageRequestOptions()
    options.isNetworkAccessAllowed = true
    options.deliveryMode = .highQualityFormat
    options.isSynchronous = true
    // .current renders the user's edits; .original ignores them.
    options.version = edited ? .current : .original

    // requestImageDataAndOrientation rather than requestImage: the latter is
    // display-oriented and returns nil in cases where the data request still
    // succeeds. Downscaling is then done by ImageIO, which decodes only what
    // it needs for the target size.
    var imageData: Data?
    var failureDetail = ""
    PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
        imageData = data
        if data == nil {
            let reason = info?[PHImageErrorKey] as? Error
            failureDetail = reason.map { ": \($0.localizedDescription)" } ?? ""
        }
    }

    guard let data = imageData else {
        // Videos have no still image to fetch this way; the caller treats a
        // missing thumbnail as non-fatal.
        fail("no image data for \(localIdentifier)\(failureDetail)")
    }

    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
        fail("could not read image data for \(localIdentifier)")
    }

    let thumbnailOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        // Honour the EXIF orientation, otherwise previews come out rotated.
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: spec.maxPixels,
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
        fail("could not render thumbnail for \(localIdentifier)")
    }

    guard let jpeg = encodeJPEG(cgImage, maxBytes: spec.maxBytes) else {
        fail("could not fit thumbnail for \(localIdentifier) under \(spec.maxBytes) bytes")
    }

    FileHandle.standardOutput.write(jpeg)
}

// MARK: - Entry point

let args = CommandLine.arguments

guard args.count >= 2 else {
    fail("usage: photos-helper list | export <localIdentifier> [--edited] | thumbnail <localIdentifier> --type <1|2> [--edited]")
}

guard requestAuthorization() else {
    fail("Photos library access was not granted")
}

switch args[1] {
case "list":
    listAssets()
case "export":
    guard args.count >= 3 else {
        fail("usage: photos-helper export <localIdentifier> [--edited]")
    }
    let edited = args.contains("--edited")
    exportAsset(localIdentifier: args[2], edited: edited)
case "thumbnail":
    guard args.count >= 3 else {
        fail("usage: photos-helper thumbnail <localIdentifier> --type <1|2> [--edited]")
    }
    var type = 1
    if let typeIndex = args.firstIndex(of: "--type"), typeIndex + 1 < args.count {
        type = Int(args[typeIndex + 1]) ?? 1
    }
    writeThumbnail(localIdentifier: args[2], edited: args.contains("--edited"), type: type)
default:
    fail("unknown subcommand: \(args[1])")
}
