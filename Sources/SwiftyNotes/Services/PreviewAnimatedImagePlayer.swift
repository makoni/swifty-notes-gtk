import Adwaita
import Foundation

@MainActor
final class PreviewAnimatedImagePlayer {
    private let player: AnimatedImagePlayer

    init?(localURL: URL, picture: Picture, preferredHeight: Int? = nil, autoSchedule: Bool = true) {
        let loaded: AnimatedImagePlayer?
        do {
            loaded = try AnimatedImagePlayer(contentsOf: localURL, displayedBy: picture)
        } catch {
            return nil
        }
        guard let loaded else { return nil }

        self.player = loaded
        Self.applyPreferredSizing(picture: picture, metadata: loaded.metadata, preferredHeight: preferredHeight)
        if autoSchedule {
            loaded.start()
        }
    }

    func advanceFrame() {
        player.advanceFrame()
    }

    func stop() {
        player.stop()
    }

    private static func applyPreferredSizing(
        picture: Picture,
        metadata: AnimatedImagePlayer.Metadata,
        preferredHeight: Int?
    ) {
        guard let preferredHeight, preferredHeight > 0 else { return }
        let width = PreviewImagePaintableLoader.scaledWidth(
            intrinsicWidth: Double(metadata.width),
            intrinsicHeight: Double(metadata.height),
            preferredHeight: preferredHeight
        )
        picture.setSizeRequest(width: width ?? -1, height: preferredHeight)
    }
}
