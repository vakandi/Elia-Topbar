import Foundation
import AppKit

/// Manages agent profile photos stored locally in the app's Application Support folder.
/// Photos are copied INTO the app's own folder so they never get lost.
/// A JSON file maps agent names to their photo filenames.
@MainActor
final class ProfilePhotos {
    static let shared = ProfilePhotos()

    private let profilesJSON: URL
    private let photosDir: URL
    private var profiles: [String: String] = [:]  // agentName -> filename

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let base = appSupport.appendingPathComponent("EliaTopBar", isDirectory: true)
        photosDir = base.appendingPathComponent("agent_photos", isDirectory: true)
        profilesJSON = base.appendingPathComponent("agent_profiles.json")

        // Ensure directories exist
        try? FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Public API

    /// Returns the NSImage for an agent's profile photo, or nil if none set.
    func photo(for agentName: String) -> NSImage? {
        guard let filename = profiles[agentName] else { return nil }
        let path = photosDir.appendingPathComponent(filename)
        return NSImage(contentsOf: path)
    }

    /// Returns a circular cropped version of the agent's photo, or nil.
    func circularPhoto(for agentName: String, size: CGFloat) -> NSImage? {
        guard let original = photo(for: agentName) else { return nil }
        return circularCrop(original, size: size)
    }

    /// Sets a profile photo for an agent by copying the file into the app folder.
    func setPhoto(for agentName: String, sourceURL: URL) -> Bool {
        // Access the security-scoped resource
        let gotAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if gotAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }

        // Determine extension
        let ext = sourceURL.pathExtension.lowercased()
        let validExts = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff"]
        let storeExt = validExts.contains(ext) ? ext : "png"

        // Remove old photo if exists
        removePhoto(for: agentName)

        // Copy new photo into app folder
        let destFilename = "\(agentName).\(storeExt)"
        let destURL = photosDir.appendingPathComponent(destFilename)

        do {
            // Remove existing file at destination
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } catch {
            AppLog.d("Failed to copy photo for \(agentName): \(error.localizedDescription)")
            return false
        }

        profiles[agentName] = destFilename
        save()
        AppLog.d("Set profile photo for \(agentName): \(destFilename)")
        return true
    }

    /// Removes the profile photo for an agent.
    func removePhoto(for agentName: String) {
        if let filename = profiles.removeValue(forKey: agentName) {
            let path = photosDir.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: path)
            save()
            AppLog.d("Removed profile photo for \(agentName)")
        }
    }

    /// Returns true if an agent has a profile photo.
    func hasPhoto(for agentName: String) -> Bool {
        profiles[agentName] != nil
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: profilesJSON.path),
              let data = try? Data(contentsOf: profilesJSON),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            profiles = [:]
            return
        }
        profiles = decoded
    }

    private func save() {
        guard let data = try? JSONSerialization.data(withJSONObject: profiles, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: profilesJSON, options: .atomic)
    }

    // MARK: - Image Utilities

    /// Crops an NSImage into a circle of the given size.
    private func circularCrop(_ image: NSImage, size: CGFloat) -> NSImage {
        let output = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect)
            path.addClip()

            // Draw the image scaled to fill
            let imageSize = image.size
            let aspectWidth = rect.width / imageSize.width
            let aspectHeight = rect.height / imageSize.height
            let scaleFactor = max(aspectWidth, aspectHeight) // fill, not fit

            let drawWidth = imageSize.width * scaleFactor
            let drawHeight = imageSize.height * scaleFactor
            let drawRect = NSRect(
                x: (rect.width - drawWidth) / 2,
                y: (rect.height - drawHeight) / 2,
                width: drawWidth,
                height: drawHeight
            )
            image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            return true
        }
        output.isTemplate = false
        return output
    }
}
