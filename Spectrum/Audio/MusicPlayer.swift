import Foundation
import MediaPlayer
import AVFoundation

/// Manages music library access and playback state for music mode.
///
/// Queries the device's music library via `MPMediaQuery`, filters out
/// DRM-protected tracks using `hasProtectedAsset`, and groups results
/// by artist. Playback state (current track, playing/paused) is
/// published for SwiftUI to drive the transport controls.
///
/// The library is loaded exactly once — reloading under different audio
/// session states gives inconsistent `AVAudioFile` validation results.
class MusicPlayer: ObservableObject {
    /// Tracks grouped by artist, sorted alphabetically. Each artist's songs
    /// are sorted by title. Only non-DRM tracks with an assetURL are included.
    @Published var tracks: [(artist: String, songs: [MPMediaItem])] = []
    /// The currently selected/playing track, or nil if nothing is loaded.
    @Published var currentTrack: MPMediaItem?
    /// Whether the current track is playing (true) or paused (false).
    /// ContentView observes this to drive AudioEngine pause/resume.
    @Published var isPlaying = false
    /// Whether the user has granted Media & Apple Music permission.
    @Published var hasLibraryAccess = false
    /// Whether the library scan has completed (shows loading spinner until true).
    @Published var libraryLoaded = false

    /// Requests library permission if needed, then loads and filters the library.
    /// Guarded by `libraryLoaded` — only runs once per app lifetime.
    func requestAccessAndLoad() {
        guard !libraryLoaded else { return }
        let status = MPMediaLibrary.authorizationStatus()
        switch status {
        case .authorized:
            hasLibraryAccess = true
            loadLibrary()
        case .notDetermined:
            MPMediaLibrary.requestAuthorization { [weak self] newStatus in
                DispatchQueue.main.async {
                    self?.hasLibraryAccess = newStatus == .authorized
                    if newStatus == .authorized {
                        self?.loadLibrary()
                    }
                    self?.libraryLoaded = true
                }
            }
        default:
            hasLibraryAccess = false
            libraryLoaded = true
        }
    }

    /// Loads the music library, filtering out DRM-protected and URL-less tracks.
    ///
    /// Uses `hasProtectedAsset` (iOS 9.2+) for DRM detection. Since 2024,
    /// all iTunes Store purchases are DRM-free, so this reliably identifies
    /// purchased/imported tracks. `AVAudioFile(forReading:)` validation was
    /// removed — it gives false negatives under `.playAndRecord` session mode.
    private func loadLibrary() {
        guard let query = MPMediaQuery.songs().items else {
            libraryLoaded = true
            return
        }

        // Diagnostic: dump attributes for every track to help identify
        // DRM vs non-DRM differentiators beyond hasProtectedAsset
        // (Commented out — used to discover .movpkg filter, kept for future debugging)
//        for item in query {
//            let title = item.title ?? "?"
//            let artist = item.artist ?? "?"
//            let url = item.assetURL
//            let protected = item.hasProtectedAsset
//            let cloud = item.isCloudItem
//            let mediaType = item.mediaType.rawValue
//            let playCount = item.playCount
//            let dateAdded = item.dateAdded
//            let duration = item.playbackDuration
//            let albumTitle = item.albumTitle ?? "?"
//
//            // Try opening with AVAudioFile to see if it's actually readable
//            var avReadable = "no URL"
//            if let url = url {
//                do {
//                    let _ = try AVAudioFile(forReading: url)
//                    avReadable = "YES"
//                } catch {
//                    avReadable = "NO (\(error.localizedDescription))"
//                }
//            }
//
//            print("🎵 TRACK: \"\(title)\" by \(artist) | album=\"\(albumTitle)\" | protected=\(protected) | cloud=\(cloud) | mediaType=\(mediaType) | duration=\(String(format: "%.0f", duration))s | playCount=\(playCount) | added=\(dateAdded) | url=\(url?.lastPathComponent ?? "nil") | AVAudioFile=\(avReadable)")
//        }

        var noUrl = 0, drm = 0, movpkg = 0
        let eligible = query.filter { item in
            guard let url = item.assetURL else { noUrl += 1; return false }
            if item.hasProtectedAsset { drm += 1; return false }
            // .movpkg = Apple Music cached streaming package — looks local
            // (cloud=false, protected=false) but AVAudioFile can't read it
            if url.pathExtension.lowercased() == "movpkg" { movpkg += 1; return false }
            return true
        }
        print("🎵 Music library: \(eligible.count) playable, \(noUrl) no URL, \(drm) DRM, \(movpkg) movpkg (cached stream), out of \(query.count) total")
        // Log track list to spectrum.log for automated testing
        if let logPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("spectrum.log"),
           let handle = FileHandle(forWritingAtPath: logPath.path) {
            handle.seekToEndOfFile()
            for item in eligible {
                let line = "TRACK: \(item.artist ?? "?") — \(item.title ?? "?")\n"
                handle.write(line.data(using: .utf8)!)
            }
            handle.closeFile()
        }

        // Group by artist, sorted case-insensitively
        var grouped: [String: [MPMediaItem]] = [:]
        for item in eligible {
            let artist = item.artist ?? "Unknown Artist"
            grouped[artist, default: []].append(item)
        }

        let sorted = grouped.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        tracks = sorted.map { artist in
            let songs = grouped[artist]!.sorted { ($0.title ?? "").localizedCaseInsensitiveCompare($1.title ?? "") == .orderedAscending }
            return (artist: artist, songs: songs)
        }

        libraryLoaded = true
    }

    /// Selects a track and sets playing state. ContentView then calls
    /// AudioEngine.playFile() with the track's assetURL.
    func selectTrack(_ item: MPMediaItem) {
        currentTrack = item
        isPlaying = true
    }

    /// Clears the current track and stops playback state.
    func stop() {
        currentTrack = nil
        isPlaying = false
    }

    /// Formatted display name for the transport bar: "Artist — Title".
    var trackDisplayName: String {
        guard let track = currentTrack else { return "" }
        let title = track.title ?? "Unknown"
        let artist = track.artist ?? "Unknown Artist"
        return "\(artist) — \(title)"
    }

    /// Formats a duration in seconds as "M:SS" for display in the track list.
    static func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
