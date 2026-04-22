import Adwaita
import Foundation

@MainActor
enum PreviewImagePaintableLoader {
    static func loadImage(
        at localURL: URL,
        into picture: Picture,
        preferredHeight: Int? = nil,
        constrainWidthToAspectRatio: Bool = false,
        completion: (@MainActor () -> Void)? = nil,
    ) {
        // NB: the earlier `Task { @MainActor in await Texture.load(...) }`
        // path never ran under GLib's main loop — GTK apps can't drain
        // Swift's DispatchQueue.main. Decode synchronously instead.
        // `Texture.loadSynchronously(from:)` goes through GdkPixbuf so we
        // pick up any raster format the host registered (PNG, JPEG, WebP,
        // GIF, TIFF, BMP). SVG/SVGZ still takes the filename path — GTK
        // rasterizes it lazily via the `GFile` side of the Picture.
        let ext = localURL.pathExtension.lowercased()
        let isSVG = (ext == "svg" || ext == "svgz")
        let filesystemPath = localURL.path(percentEncoded: false)

        if !isSVG, let texture = try? Texture.loadSynchronously(from: localURL) {
            picture.setPaintable(texture)
        } else {
            picture.setFilename(filesystemPath)
        }

        applyPreferredSizing(
            to: picture,
            preferredHeight: preferredHeight,
            constrainWidthToAspectRatio: constrainWidthToAspectRatio,
            svgURL: isSVG ? localURL : nil,
        )
        completion?()
    }

    static func scaledWidth(
        intrinsicWidth: Double,
        intrinsicHeight: Double,
        preferredHeight: Int,
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
        svgURL: URL?,
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
               preferredHeight: preferredHeight,
           )
        {
            picture.setSizeRequest(width: width, height: preferredHeight)
            return
        }

        if let size = picture.intrinsicSize,
           let width = scaledWidth(
               intrinsicWidth: Double(size.width),
               intrinsicHeight: Double(size.height),
               preferredHeight: preferredHeight,
           )
        {
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
              let height = extractSVGDimension(named: "height", from: content)
        else {
            return nil
        }
        return (width, height)
    }

    static func extractSVGDimension(named name: String, from content: String) -> Double? {
        let pattern = #"\b\#(name)\s*=\s*"([0-9]+(?:\.[0-9]+)?)(?:px)?""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: content,
                  range: NSRange(content.startIndex..., in: content),
              ),
              let valueRange = Range(match.range(at: 1), in: content)
        else {
            return nil
        }
        return Double(content[valueRange])
    }
}
