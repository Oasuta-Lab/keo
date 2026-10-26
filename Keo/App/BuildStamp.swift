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

/// Only on the connection screen now. On the home screen the stamp is behind ten taps on the
/// logo (`HomeView.knock`): it is support information, consulted perhaps twice a year, and it
/// was holding a permanent line on the one page the owner opens every day. Here it stays
/// visible, because this is the screen you are on when nothing works yet and there is no home
/// page to tap.
///
/// Deliberately quiet: small, dimmed, and behind a material so it stays legible over a photo.
struct BuildStampLabel: View {
    var body: some View {
        Text(BuildStamp.text)
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
            .allowsHitTesting(false)
            .accessibilityLabel("Version \(BuildStamp.text)")
    }
}
