import SwiftUI

/// Identifies the binary in the hand. The build number is the commit count, stamped at build
/// time by `Scripts/stamp-build.sh`; the short SHA carries a trailing `+` when the build was
/// made with uncommitted changes.
enum BuildStamp {
    static let text: String = {
        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let commit = bundle.infoDictionary?["KeoCommit"] as? String ?? "dev"
        return "v\(version) (\(build)) · \(commit)"
    }()
}

/// Deliberately quiet: small, dimmed, and behind a material so it stays legible over a photo.
struct BuildStampLabel: View {
    var body: some View {
        Text(BuildStamp.text)
            .font(.system(size: 10, weight: .regular, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
            .allowsHitTesting(false)
            .accessibilityLabel("Version \(BuildStamp.text)")
    }
}
