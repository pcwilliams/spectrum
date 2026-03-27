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

    @State private var dragOffset: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle + header
            VStack(spacing: 6) {
                Capsule()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 36, height: 4)
                    .padding(.top, 8)

                HStack {
                    Text("Music Library")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        // Only allow downward drag
                        dragOffset = max(0, value.translation.height)
                    }
                    .onEnded { value in
                        if value.translation.height > 80 || value.velocity.height > 500 {
                            onClose()
                        }
                        withAnimation(.easeOut(duration: 0.2)) {
                            dragOffset = 0
                        }
                    }
            )

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
        .offset(y: dragOffset)
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
