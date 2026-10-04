import Foundation

/// Translates the advisory strings the daemon reports in `DaemonStatus.warnings`.
///
/// The daemon composes these in English (the CLI prints the same text), so the app looks each one
/// up by its English text. Their catalog entries are marked `manual` because the compiler can't
/// see a key that arrives over IPC; a warning without an entry shows in English.
enum DaemonWarning {
    static func localized(_ warning: String) -> String {
        Bundle.main.localizedString(forKey: warning, value: warning, table: nil)
    }
}
