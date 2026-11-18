import Foundation

/// What told the app that a plugin draws pictures in the terminal.
struct PluginPictureNeed: Equatable, Sendable {
    /// The words it used, as found.
    let phrase: String
    /// The file that says so: `README.md`, `herdr-plugin/herdr-plugin.toml`.
    let file: String
}

/// Whether a plugin draws pictures in the terminal, going by its own words.
///
/// AI Manager shows no pictures, and a program that draws them fills its pane
/// with nothing while Herdr sends every frame over the connection: megabytes a
/// second, enough to freeze the session. Such a plugin is not installed from
/// the app.
///
/// A plugin's manifest has no field for this, so its README and manifest are
/// read for the phrases plugins use. Checked on 2026-11-18 against the 120 most
/// starred plugins in Herdr's marketplace: five say "kitty graphics", all five
/// draw pictures (terminal-browser, terminal-code, herdr-browser,
/// herdr-plannotator, herdr-pet), and nothing else matched.
enum PluginPictureRequirement {
    static let phrases = ["kitty graphics", "kitty-graphics", "graphics protocol", "sixel"]

    /// The phrase in `text` that says the plugin draws pictures, if there is one.
    static func phrase(in text: String) -> String? {
        let lowered = text.lowercased()
        return phrases.first { lowered.contains($0) }
    }
}
