import SwiftUI
import MediaPlayer

/// Scrollable music library browser shown at the bottom of the screen.
/// Displays tracks grouped by artist, with a playing indicator (cyan speaker
/// icon) next to the current track. Supports drag-to-dismiss gesture.
///
/// Shows appropriate empty states for: no library access, no eligible tracks
/// (all DRM), or library still loading.
struct MusicBrowserView: View {
    @ObservedObject var musicPlayer: MusicPlayer
    var onTrackSelected: (MPMediaItem) -> Void
    var onClose: () -> Void


    var body: some View {
        VStack(spacing: 0) {
            Divider().background(Color.white.opacity(0.1))

            // Content
            if !musicPlayer.hasLibraryAccess {
                unavailableView(
                    icon: "music.note",
                    title: "Music Library Access Required",
                    message: "Enable in Settings > Privacy & Security > Media & Apple Music"
                )
            } else if musicPlayer.tracks.isEmpty && musicPlayer.libraryLoaded {
                unavailableView(
                    icon: "music.note.list",
                    title: "No Eligible Tracks",
                    message: "Apple Music subscription tracks are DRM-protected. Only purchased or imported tracks are available."
                )
            } else if !musicPlayer.libraryLoaded {
                Spacer()
                ProgressView("Loading library…")
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
            } else {
                trackList
            }
        }
        .background(.ultraThinMaterial)
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(.white.opacity(0.15)),
            alignment: .top
        )
    }

    private func unavailableView(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundColor(.white.opacity(0.3))
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var trackList: some View {
        List {
            ForEach(musicPlayer.tracks, id: \.artist) { section in
                Section(header: Text(section.artist).foregroundColor(.white.opacity(0.5))) {
                    ForEach(section.songs, id: \.persistentID) { item in
                        Button {
                            onTrackSelected(item)
                        } label: {
                            HStack {
                                if musicPlayer.currentTrack?.persistentID == item.persistentID {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(.cyan)
                                        .frame(width: 20)
                                } else {
                                    Text("")
                                        .frame(width: 20)
                                }

                                Text(item.title ?? "Unknown")
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                Spacer()
                                Text(MusicPlayer.formatDuration(item.playbackDuration))
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.4))
                            }
                        }
                        .listRowBackground(Color.clear)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}
