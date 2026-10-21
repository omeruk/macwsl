import SwiftUI

/// A box drawn with a 1 pt line, with an optional title on its top border at the left and
/// another at the right, as every pane and panel in the design has.
struct Box<Content: View>: View {
    var title: String?
    /// Secondary text after the title, in `text.secondary`, such as the count in
    /// `distributions (0)`.
    var titleDetail: String?
    var trailingTitle: String?
    var titleColor: ThemeColor
    var trailingTitleColor: ThemeColor?
    var borderColor: ThemeColor
    /// 12 pt top, 14 pt horizontal, 10 pt bottom: the pane box padding from the design README.
    var padding = EdgeInsets(top: 12, leading: 14, bottom: 10, trailing: 14)
    @ViewBuilder var content: Content

    @Environment(\.chrome) private var chrome

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay {
                Rectangle()
                    .strokeBorder(borderColor.color, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                if let title {
                    borderTitle(title, color: titleColor, detail: titleDetail)
                        .offset(x: 10, y: -10)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let trailingTitle {
                    borderTitle(trailingTitle, color: trailingTitleColor ?? titleColor)
                        .offset(x: -10, y: -10)
                }
            }
    }

    private func borderTitle(_ text: String, color: ThemeColor, detail: String? = nil)
        -> some View
    {
        var title = Text(text).foregroundColor(color.color)
        if let detail {
            title = title + Text(" " + detail).foregroundColor(chrome.textSecondary.color)
        }
        return
            title
            .font(MawFonts.chromeFont())
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 6)
            .frame(height: MawFonts.chromeLineHeight)
            .background(chrome.background.color, ignoresSafeAreaEdges: [])
            .allowsHitTesting(false)
    }
}
