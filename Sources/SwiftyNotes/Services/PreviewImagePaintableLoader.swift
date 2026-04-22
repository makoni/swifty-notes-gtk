import Adwaita
import Foundation

@MainActor
enum PreviewImagePaintableLoader {
    static func loadImage(
        at localURL: URL,
        into picture: Picture,
        preferredHeight: Int? = nil,
        constrainWidthToAspectRatio: Bool = false,
        completion: (@MainActor () -> Void)? = nil
    ) {
        let lowercasedExtension = localURL.pathExtension.lowercased()

        if lowercasedExtension == "svg" || lowercasedExtension == "svgz" {
            picture.setFilename(localURL.path(percentEncoded: false))
            applyPreferredSizing(
                to: picture,
                preferredHeight: preferredHeight,
                constrainWidthToAspectRatio: constrainWidthToAspectRatio,
                svgURL: localURL
            )
            completion?()
            return
        }

        Task { @MainActor in
            if let texture = try? await Texture.load(from: localURL) {
                picture.setPaintable(texture)
            } else {
                picture.setFilename(localURL.path(percentEncoded: false))
            }
            applyPreferredSizing(
                to: picture,
                preferredHeight: preferredHeight,
                constrainWidthToAspectRatio: constrainWidthToAspectRatio,
                svgURL: nil
            )
            completion?()
        }
    }

    static func scaledWidth(
        intrinsicWidth: Double,
        intrinsicHeight: Double,
        preferredHeight: Int
    ) -> Int? {
        guard intrinsicWidth > 0, intrinsicHeight > 0, preferredHeight > 0 else {
            return nil
        }
        return max(Int((Double(preferredHeight) * intrinsicWidth / intrinsicHeight).rounded()), 1)
    }
}

private extension PreviewImagePaintableLoader {
    static func applyPreferredSizing(
        to picture: Picture,
        preferredHeight: Int?,
        constrainWidthToAspectRatio: Bool,
        svgURL: URL?
    ) {
        guard let preferredHeight, preferredHeight > 0 else { return }
        guard constrainWidthToAspectRatio else {
            picture.setSizeRequest(width: -1, height: preferredHeight)
            return
        }

        if let svgURL,
           let dimensions = svgDimensions(from: svgURL),
           let width = scaledWidth(
               intrinsicWidth: dimensions.width,
               intrinsicHeight: dimensions.height,
               preferredHeight: preferredHeight
           ) {
            picture.setSizeRequest(width: width, height: preferredHeight)
            return
        }

        if let size = picture.intrinsicSize,
           let width = scaledWidth(
               intrinsicWidth: Double(size.width),
               intrinsicHeight: Double(size.height),
               preferredHeight: preferredHeight
           ) {
            picture.setSizeRequest(width: width, height: preferredHeight)
            return
        }

        picture.setSizeRequest(width: -1, height: preferredHeight)
    }

    static func svgDimensions(from localURL: URL) -> (width: Double, height: Double)? {
        let ext = localURL.pathExtension.lowercased()
        guard ext == "svg" || ext == "svgz",
              let data = try? Data(contentsOf: localURL),
              let content = String(data: data.prefix(4096), encoding: .utf8),
              let width = extractSVGDimension(named: "width", from: content),
              let height = extractSVGDimension(named: "height", from: content) else {
            return nil
        }
        return (width, height)
    }

    static func extractSVGDimension(named name: String, from content: String) -> Double? {
        let pattern = #"\b\#(name)\s*=\s*"([0-9]+(?:\.[0-9]+)?)(?:px)?""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: content,
                  range: NSRange(content.startIndex..., in: content)
              ),
              let valueRange = Range(match.range(at: 1), in: content) else {
            return nil
        }
        return Double(content[valueRange])
    }
}
