import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

struct DisplaySnapshot {
    let screen: NSScreen
    let image: CGImage

    var size: CGSize { screen.frame.size }
    var pixelScale: CGSize {
        CGSize(width: CGFloat(image.width) / size.width, height: CGFloat(image.height) / size.height)
    }

    func crop(_ selection: CGRect, outline: [CGPoint] = []) -> CGImage? {
        cropImage(image, to: selection, scale: pixelScale, outline: outline)
    }
}

func cropImage(_ image: CGImage, to selection: CGRect, scale: CGSize, outline: [CGPoint]) -> CGImage? {
    let bounds = CGRect(x: selection.minX * scale.width, y: selection.minY * scale.height,
                        width: selection.width * scale.width, height: selection.height * scale.height)
        .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard !bounds.isEmpty, let cropped = image.cropping(to: bounds) else { return nil }
    guard !outline.isEmpty else { return cropped }

    let colorSpace = cropped.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        ?? CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: cropped.width, height: cropped.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let path = CGMutablePath()
    path.addLines(between: outline.map {
        CGPoint(x: $0.x * scale.width - bounds.minX,
                y: bounds.maxY - $0.y * scale.height)
    })
    path.closeSubpath()
    context.addPath(path)
    context.clip(using: .evenOdd)
    context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
    return context.makeImage()
}

struct SelectableWindow {
    let window: SCWindow
    let bounds: CGRect

    static func frontToBack(from windows: [SCWindow]) -> [Self] {
        let byID = Dictionary(uniqueKeysWithValues: windows.filter {
            $0.windowLayer == 0 && $0.isOnScreen && !$0.frame.isEmpty
        }.map { ($0.windowID, $0) })
        let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return entries.compactMap {
            guard let id = $0[kCGWindowNumber as String] as? UInt32, let window = byID[id],
                  let alpha = $0[kCGWindowAlpha as String] as? Double, alpha > 0,
                  let rawBounds = $0[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary)
            else { return nil }
            return Self(window: window, bounds: bounds)
        }
    }
}

enum CaptureFailure: LocalizedError {
    case noDisplay, noImage, clipboard

    var errorDescription: String? {
        switch self {
        case .noDisplay: "SnipBar couldn’t find an available display."
        case .noImage: "SnipBar couldn’t create the screenshot."
        case .clipboard: "SnipBar couldn’t copy the screenshot to the clipboard."
        }
    }
}

@MainActor
enum Capture {
    static func display(_ display: SCDisplay, screen: NSScreen,
                        excluding applications: [SCRunningApplication]) async throws -> DisplaySnapshot {
        let filter = SCContentFilter(display: display, excludingApplications: applications, exceptingWindows: [])
        let bounds = screen.convertRectToBacking(screen.frame)
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration(size: bounds.size))
        return DisplaySnapshot(screen: screen, image: image)
    }

    static func window(_ window: SCWindow, scale: CGFloat) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = configuration(size: CGSize(width: window.frame.width * scale,
                                                height: window.frame.height * scale))
        config.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private static func configuration(size: CGSize) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = max(1, Int(size.width.rounded()))
        config.height = max(1, Int(size.height.rounded()))
        config.showsCursor = false
        return config
    }

    static func deliver(_ image: CGImage, output: Output, folder: URL) throws -> String {
        let data = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { throw CaptureFailure.noImage }
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder) else { throw CaptureFailure.noImage }

        if output.copiesImage {
            let item = NSPasteboardItem()
            item.setData(data as Data, forType: .png)
            if let tiff = NSBitmapImageRep(cgImage: image).tiffRepresentation {
                item.setData(tiff, forType: .tiff)
            }
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.writeObjects([item]) else { throw CaptureFailure.clipboard }
        }

        if output.savesFile {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let time = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)
                    .timeSeparator(.omitted).dateTimeSeparator(.space).timeZone(separator: .omitted))
                let suffix = UUID().uuidString.prefix(6)
                let destination = folder.appendingPathComponent("Snip \(time) \(suffix).png")
                try (data as Data).write(to: destination, options: .atomic)
            } catch {
                let prefix = output.copiesImage ? "The snip was copied. Saving failed." : "Saving the snip failed."
                throw NSError(domain: "SnipBar.Save", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "\(prefix) \(error.localizedDescription)"
                ])
            }
        }

        switch output {
        case .clipboard: return "Copied to clipboard"
        case .file: return "Screenshot saved"
        case .both: return "Saved and copied"
        }
    }
}

extension NSScreen {
    var captureDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

@MainActor
extension Capture {
    static func prepare() async throws -> ([DisplaySnapshot], [SelectableWindow]) {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let apps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let windows = SelectableWindow.frontToBack(from: content.windows.filter {
            $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
        })
        let displays = Dictionary(uniqueKeysWithValues: content.displays.map { ($0.displayID, $0) })
        let screens = NSScreen.screens
        let snapshots = try await withThrowingTaskGroup(of: DisplaySnapshot.self) { group in
            for screen in screens {
                guard let id = screen.captureDisplayID, let display = displays[id] else { continue }
                group.addTask { @MainActor in try await Capture.display(display, screen: screen, excluding: apps) }
            }
            var result: [DisplaySnapshot] = []
            for try await snapshot in group { result.append(snapshot) }
            return result
        }
        guard !snapshots.isEmpty else { throw CaptureFailure.noDisplay }
        return (snapshots, windows)
    }
}
