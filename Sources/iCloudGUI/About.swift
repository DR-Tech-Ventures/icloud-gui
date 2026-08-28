import AppKit
import SwiftUI

enum About {
    static let repository = "https://github.com/DR-Tech-Ventures/icloud-gui"
    private static let license = "https://www.apache.org/licenses/LICENSE-2.0"

    /// Replaces the default About item. The stock panel shows only name, version and
    /// copyright; for an open-source app the licence and where to get the source
    /// matter just as much, and this is where people look for them.
    @MainActor
    static func show() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            .applicationName: "iCloud GUI",
        ])
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private static var credits: NSAttributedString {
        let body = NSFont.systemFont(ofSize: 11)
        let text = NSMutableAttributedString()

        func para(_ s: String, spacingAfter: CGFloat = 8) {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.paragraphSpacing = spacingAfter
            text.append(NSAttributedString(string: s + "\n", attributes: [
                .font: body,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style,
            ]))
        }
        func link(_ label: String, _ url: String, spacingAfter: CGFloat = 4) {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.paragraphSpacing = spacingAfter
            text.append(NSAttributedString(string: label + "\n", attributes: [
                .font: body,
                .link: URL(string: url) as Any,
                .paragraphStyle: style,
            ]))
        }

        // Kept short deliberately: the About panel's credits area is fixed height and
        // silently clips anything taller, rather than growing to fit.
        para("Download your iCloud photos to this Mac or a NAS.")
        para("Your Apple ID password is never requested or stored.", spacingAfter: 10)
        para("Open source under the Apache License 2.0.", spacingAfter: 4)
        link("View the source", repository)
        link("Read the license", license, spacingAfter: 0)
        return text
    }
}
