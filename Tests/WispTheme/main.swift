//
//  Theme suite: contrast for every theme in light and dark, theme structure, the
//  contrast helpers themselves, and the guarantee that Sage is the original look.
//

import Foundation

@MainActor func runAllTests() {
var failureCount = 0
var checkCount = 0

func check(_ condition: Bool, _ description: String) {
    checkCount += 1
    if !condition {
        failureCount += 1
        print("FAIL: \(description)")
    }
}

func isClose(_ first: Double, _ second: Double, tolerance: Double = 0.01) -> Bool {
    abs(first - second) < tolerance
}

// MARK: - Contrast helpers

check(isClose(WispThemeContrast.ratio(foregroundHex: "#000000", backgroundHex: "#FFFFFF"), 21.0),
      "black on white is 21:1")
check(isClose(WispThemeContrast.ratio(foregroundHex: "#FFFFFF", backgroundHex: "#FFFFFF"), 1.0),
      "same colour is 1:1")
check(isClose(
    WispThemeContrast.ratio(foregroundHex: "#777777", backgroundHex: "#FFFFFF"),
    WispThemeContrast.ratio(foregroundHex: "#FFFFFF", backgroundHex: "#777777")),
      "ratio is symmetric")
check(isClose(WispThemeContrast.ratio(foregroundHex: "#767676", backgroundHex: "#FFFFFF"), 4.54),
      "#767676 on white is the well-known 4.54:1")
check(WispThemeContrast.blendedHex(foregroundHex: "#FF0000", alpha: 0.5, overBackgroundHex: "#000000") == "#800000",
      "50% red over black is #800000")
check(WispThemeContrast.blendedHex(foregroundHex: "#FF0000", alpha: 0, overBackgroundHex: "#102030") == "#102030",
      "alpha 0 leaves the background")
check(WispThemeContrast.blendedHex(foregroundHex: "#FF0000", alpha: 1, overBackgroundHex: "#102030") == "#FF0000",
      "alpha 1 is the foreground")
check(WispThemeContrast.isValidHex("#a1B2c3"), "mixed-case hex parses")
check(!WispThemeContrast.isValidHex("A1B2C3") && !WispThemeContrast.isValidHex("#ABC") && !WispThemeContrast.isValidHex("#GGGGGG"),
      "malformed hex is rejected")

// MARK: - Every theme

check(WispTheme.all.count == 6, "six themes")
check(Set(WispTheme.all.map { $0.id }).count == WispTheme.all.count, "theme ids are unique")
check(WispTheme.all.map { $0.id } == WispThemeID.allCases, "picker order matches the id enum")
check(Set(WispTheme.all.map { $0.name }).count == WispTheme.all.count, "theme names are unique")
check(WispTheme.all.map { $0.name } == ["Sage", "Candy", "Sunset", "Mint", "Berry Night", "Mono"], "names, in picker order")
check(WispTheme.defaultTheme.id == .sage, "Sage is the default")

for theme in WispTheme.all {
    check(theme.backdropStops.count == 3, "\(theme.name): 3 backdrop stops")
    check(theme.buddyPalette.count == 8 && theme.buddyPalette.count == WispTheme.buddyPaletteCount,
          "\(theme.name): 8 buddy colours")
    check(WispTheme.theme(withID: theme.id) == theme, "\(theme.name): lookup by id")

    for problem in WispThemeContrast.failures(for: theme) {
        check(false, problem)
    }

    // Buddies must stay tellable apart inside a theme.
    check(Set(theme.buddyPalette.map { $0.lightHex }).count == 8, "\(theme.name): buddy body tones are distinct")
    check(Set(theme.buddyPalette.map { $0.deepHex }).count == 8, "\(theme.name): buddy deep tones are distinct")

    // The island tint must read as dark, or "tinted" would stop looking like the notch.
    check(WispThemeContrast.relativeLuminance(ofHex: theme.islandTintHex) < 0.03,
          "\(theme.name): island tint is dark")
    check(WispThemeContrast.ratio(foregroundHex: "#FFFFFF", backgroundHex: theme.islandTintHex) > 15,
          "\(theme.name): white text on the tinted island is at least 15:1")
}

// A theme with a broken structure must be reported, not crash the gate.
let brokenTheme = WispTheme(
    id: .mono, name: "Broken",
    accent: WispThemeColorPair(lightHex: "nope", darkHex: "#5C5C5C"),
    accentHover: WispTheme.mono.accentHover, accentText: WispTheme.mono.accentText,
    textOnAccentHex: "#FFFFFF", secondaryAccent: WispTheme.mono.secondaryAccent,
    aiActivityAccent: WispTheme.mono.aiActivityAccent,
    backdropStops: [WispTheme.mono.backdropStops[0]],
    buddyPalette: [], islandTintHex: "#111111", glassTintStrength: 2)
let brokenProblems = WispThemeContrast.failures(for: brokenTheme)
check(brokenProblems.contains { $0.contains("3 backdrop stops") }, "gate reports a wrong backdrop count")
check(brokenProblems.contains { $0.contains("buddy colours") }, "gate reports a wrong buddy palette size")
check(brokenProblems.contains { $0.contains("nope") }, "gate reports malformed hex")

// A theme whose accent text is too faint must fail the gate.
let faintTheme = WispTheme(
    id: .mono, name: "Faint",
    accent: WispTheme.mono.accent, accentHover: WispTheme.mono.accentHover,
    accentText: WispThemeColorPair(lightHex: "#CCCCCC", darkHex: "#333333"),
    textOnAccentHex: "#FFFFFF", secondaryAccent: WispTheme.mono.secondaryAccent,
    aiActivityAccent: WispTheme.mono.aiActivityAccent,
    backdropStops: WispTheme.mono.backdropStops, buddyPalette: WispTheme.mono.buddyPalette,
    islandTintHex: "#111111", glassTintStrength: 0.2)
check(!WispThemeContrast.failures(for: faintTheme).isEmpty, "gate fails a theme with faint accent text")

// MARK: - Sage is the original look

let sage = WispTheme.sage
check(sage.accent == WispThemeColorPair(lightHex: "#394438", darkHex: "#596653"), "sage accent = deepMoss / darkMoss")
check(sage.accentHover == WispThemeColorPair(lightHex: "#47543F", darkHex: "#67765F"), "sage accent hover unchanged")
check(sage.accentText == WispThemeColorPair(lightHex: "#394438", darkHex: "#8C9A82"), "sage accent text = deepMoss / sage")
check(sage.aiActivityAccent.darkHex == "#8F8CB5", "sage dark AI accent = muted lavender")
check(sage.backdropStops.map { $0.lightHex } == ["#9AA88F", "#C9CBC1", "#AAA7D9"], "sage signature gradient unchanged")
check(sage.buddyPalette.map { $0.lightHex } == ["#99CCAD", "#A8A3EB", "#F0B094", "#EDA6BF", "#99C7F2", "#EDD18A", "#8CD4D4", "#CCA8E0"],
      "sage buddy body tones = the original eight")
check(sage.buddyPalette.map { $0.deepHex } == ["#3F8264", "#6159BD", "#B35E44", "#B55680", "#4277BE", "#947022", "#2E808C", "#8557A3"],
      "sage buddy deep tones = the original eight, darkened until white body text holds 4.5:1")

print("\(checkCount - failureCount)/\(checkCount) checks passed")
if failureCount > 0 {
    print("\(failureCount) FAILED")
    exit(1)
}
}

MainActor.assumeIsolated { runAllTests() }
