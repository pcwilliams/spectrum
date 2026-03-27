import SwiftUI

/// Now-playing transport bar shown at the bottom when a track is loaded.
/// Displays the track name (tappable to open browser), play/pause button,
/// and stop button. Supports swipe-up gesture to reveal the music browser.
struct TransportBarView: View {
    @ObservedObject var musicPlayer: MusicPlayer
    var onBrowse: () -> Void
    var onStop: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle (swipe up to browse)
            Capsule()
                .fill(Color.white.opacity(0.2))
                .frame(width: 36, height: 4)
                .padding(.top, 6)
                .padding(.bottom, 4)

            HStack(spacing: 12) {
                // Track name (tap to browse)
                Button {
                    onBrowse()
                } label: {
                    Text(musicPlayer.trackDisplayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                }

                Spacer()

                // Play/Pause — toggling isPlaying triggers ContentView's
                // onChange handler which calls pausePlayback/resumePlayback
                Button {
                    musicPlayer.isPlaying.toggle()
                } label: {
                    Image(systemName: musicPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                }

                // Stop
                Button {
                    onStop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 36, height: 36)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .background(.ultraThinMaterial)
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onEnded { value in
                    // Swipe up to show browser
                    if value.translation.height < -30 || value.velocity.height < -300 {
                        onBrowse()
                    }
                }
        )
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(.white.opacity(0.1)),
            alignment: .top
        )
    }
}
