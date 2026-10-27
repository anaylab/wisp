//
//  WeatherCardView.swift
//  leanring-buddy
//
//  The weather glance card, drawn in Apple Weather's layout: a sky-coloured
//  panel with the current conditions, an hourly strip, and a multi-day forecast
//  with temperature-range bars. It is fed a `WeatherSnapshot` that Wisp resolves
//  from a place name (`WeatherDataProvider`), so the model never produced any of
//  these numbers.
//
//  Unlike the generic glance card, this template carries its own palette — a sky
//  gradient keyed to day/night — because looking like Weather is the whole point.
//  White text sits on that dark-enough sky in either app theme. It renders three
//  states so the card can appear the instant a turn asks for it and fill in when
//  the fetch returns: loading, loaded, and failed.
//

import SwiftUI

/// What the weather card is showing right now. The place name is carried through
/// loading and failure so the card always has a title.
enum WeatherCardState: Equatable {
    case loading(placeName: String)
    case failed(placeName: String)
    case loaded(WeatherSnapshot)
}

struct WeatherCardView: View {
    let state: WeatherCardState

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(skyGradient)
            .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            )
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case let .loading(placeName):
            placeholder(placeName: placeName, message: "Updating…")
        case let .failed(placeName):
            placeholder(placeName: placeName, message: "Weather unavailable")
        case let .loaded(snapshot):
            loadedContent(snapshot)
        }
    }

    // MARK: - Loaded

    private func loadedContent(_ snapshot: WeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            currentConditions(snapshot)
            if !snapshot.hourly.isEmpty {
                hourlyStrip(snapshot.hourly)
            }
            if !snapshot.daily.isEmpty {
                dailyForecast(snapshot.daily)
            }
            liveAttribution
        }
    }

    /// City, big current temperature, condition, and today's high/low —
    /// centered, as Weather lays it out.
    private func currentConditions(_ snapshot: WeatherSnapshot) -> some View {
        VStack(spacing: 1) {
            Text(snapshot.placeName)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
            Text("\(snapshot.current.temperature)°")
                .font(.system(size: 62, weight: .thin))
                .foregroundColor(.white)
            Text(snapshot.current.conditionText)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.95))
            Text("H:\(snapshot.current.highTemperature)°   L:\(snapshot.current.lowTemperature)°")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Hourly

    private func hourlyStrip(_ hours: [WeatherHour]) -> some View {
        HStack(alignment: .center, spacing: 0) {
            ForEach(Array(hours.enumerated()), id: \.offset) { _, hour in
                VStack(spacing: 6) {
                    Text(hour.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                    weatherGlyph(hour.symbol, isDaytime: hour.isDaytime)
                        .font(.system(size: 17))
                        .frame(height: 22)
                    Text("\(hour.temperature)°")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(glassStrip)
    }

    // MARK: - Daily

    private func dailyForecast(_ days: [WeatherDay]) -> some View {
        // One shared scale across the shown days, so the range bars are
        // comparable row to row.
        let overallLow = days.map(\.lowTemperature).min() ?? 0
        let overallHigh = days.map(\.highTemperature).max() ?? 1

        return VStack(spacing: 8) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                HStack(spacing: 10) {
                    Text(day.label)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 40, alignment: .leading)
                    weatherGlyph(day.symbol, isDaytime: true)
                        .font(.system(size: 15))
                        .frame(width: 22)
                    Text("\(day.lowTemperature)°")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 30, alignment: .trailing)
                    temperatureRangeBar(
                        low: day.lowTemperature,
                        high: day.highTemperature,
                        overallLow: overallLow,
                        overallHigh: overallHigh
                    )
                    Text("\(day.highTemperature)°")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 30, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(glassStrip)
    }

    /// The coloured segment of a day's high–low range, positioned within the
    /// week's overall range.
    private func temperatureRangeBar(low: Int, high: Int, overallLow: Int, overallHigh: Int) -> some View {
        GeometryReader { proxy in
            let span = max(overallHigh - overallLow, 1)
            let leadingFraction = CGFloat(low - overallLow) / CGFloat(span)
            let trailingFraction = CGFloat(high - overallLow) / CGFloat(span)
            let totalWidth = proxy.size.width
            let segmentX = leadingFraction * totalWidth
            let segmentWidth = max((trailingFraction - leadingFraction) * totalWidth, 6)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .frame(height: 4)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.56, green: 0.82, blue: 1.0), Color(red: 1.0, green: 0.88, blue: 0.54)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: segmentWidth, height: 4)
                    .offset(x: segmentX)
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 16)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Loading / failed placeholder

    private func placeholder(placeName: String, message: String) -> some View {
        VStack(spacing: 6) {
            Text(placeName)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Shared pieces

    /// A small label making it visible that this card fetched live data off the
    /// machine, per the local-first posture.
    private var liveAttribution: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.white.opacity(0.9))
                .frame(width: 5, height: 5)
            Text("Live · Open-Meteo")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var glassStrip: some View {
        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
            .fill(Color.white.opacity(0.15))
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            )
    }

    /// Sky palette keyed to day vs night. Night uses a deep indigo; day a clear
    /// blue. Kept fixed (not theme-derived) because a weather sky reads the same
    /// in either app theme, and white text stays legible on both.
    private var skyGradient: LinearGradient {
        let isNight: Bool
        switch state {
        case let .loaded(snapshot): isNight = !snapshot.isDaytime
        case .loading, .failed: isNight = false
        }
        let colors: [Color] = isNight
            ? [Color(red: 0.11, green: 0.16, blue: 0.29), Color(red: 0.04, green: 0.07, blue: 0.13)]
            : [Color(red: 0.31, green: 0.59, blue: 0.85), Color(red: 0.17, green: 0.38, blue: 0.64)]
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    /// Maps a weather category to an SF Symbol, choosing day/night variants where
    /// they differ. Multicolor so the sun and clouds render in their natural
    /// colours, matching Weather.
    private func weatherGlyph(_ symbol: WeatherSymbol, isDaytime: Bool) -> some View {
        let systemName: String
        switch symbol {
        case .clear: systemName = isDaytime ? "sun.max.fill" : "moon.stars.fill"
        case .partlyCloudy: systemName = isDaytime ? "cloud.sun.fill" : "cloud.moon.fill"
        case .cloudy: systemName = "cloud.fill"
        case .fog: systemName = "cloud.fog.fill"
        case .drizzle: systemName = "cloud.drizzle.fill"
        case .rain: systemName = "cloud.rain.fill"
        case .snow: systemName = "cloud.snow.fill"
        case .thunderstorm: systemName = "cloud.bolt.rain.fill"
        }
        return Image(systemName: systemName)
            .symbolRenderingMode(.multicolor)
            .foregroundColor(.white)
    }
}

#if DEBUG
private extension WeatherSnapshot {
    static var previewSample: WeatherSnapshot {
        WeatherSnapshot(
            placeName: "San Francisco",
            current: WeatherCurrent(temperature: 75, conditionText: "Sunny", symbol: .clear, highTemperature: 75, lowTemperature: 58, feelsLikeTemperature: 78),
            hourly: [
                WeatherHour(label: "Now", temperature: 75, symbol: .clear, isDaytime: true),
                WeatherHour(label: "4PM", temperature: 74, symbol: .clear, isDaytime: true),
                WeatherHour(label: "5PM", temperature: 72, symbol: .clear, isDaytime: true),
                WeatherHour(label: "6PM", temperature: 69, symbol: .partlyCloudy, isDaytime: true),
                WeatherHour(label: "7PM", temperature: 67, symbol: .partlyCloudy, isDaytime: true),
                WeatherHour(label: "8PM", temperature: 66, symbol: .clear, isDaytime: false)
            ],
            daily: [
                WeatherDay(label: "Today", highTemperature: 75, lowTemperature: 58, symbol: .clear),
                WeatherDay(label: "Tue", highTemperature: 66, lowTemperature: 59, symbol: .partlyCloudy),
                WeatherDay(label: "Wed", highTemperature: 66, lowTemperature: 60, symbol: .partlyCloudy),
                WeatherDay(label: "Thu", highTemperature: 68, lowTemperature: 59, symbol: .partlyCloudy),
                WeatherDay(label: "Fri", highTemperature: 69, lowTemperature: 58, symbol: .clear)
            ],
            isDaytime: true
        )
    }
}

#Preview("Loaded") {
    WeatherCardView(state: .loaded(.previewSample))
        .frame(width: 352)
        .padding()
        .background(DS.Colors.surface1)
}

#Preview("Loading") {
    WeatherCardView(state: .loading(placeName: "San Francisco"))
        .frame(width: 352)
        .padding()
        .background(DS.Colors.surface1)
}
#endif
