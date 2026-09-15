//
//  WeatherSnapshot.swift
//  leanring-buddy
//
//  The resolved data behind a weather glance card — everything the Apple
//  Weather–style template needs to draw, and nothing the model has to produce.
//  The model only names a place (see `WeatherCardRequest`); Wisp fetches the
//  live conditions through `WeatherDataProvider` and maps them into one of
//  these.
//
//  The mapping from Open-Meteo's response lives here as a pure, `nonisolated`
//  function so it can be unit-tested against a checked-in fixture with no live
//  network — the network fetch itself is the provider's job.
//

import Foundation

// MARK: - Snapshot model

/// A coarse weather category the renderer maps to an SF Symbol and a sky
/// palette. Derived from WMO weather codes; kept small on purpose so the
/// template only has a handful of looks to draw.
enum WeatherSymbol: String, Equatable {
    case clear
    case partlyCloudy
    case cloudy
    case fog
    case drizzle
    case rain
    case snow
    case thunderstorm

    /// Maps a WMO weather-interpretation code (what Open-Meteo returns) to a
    /// category. Unknown codes fall back to cloudy rather than nothing.
    nonisolated init(wmoCode: Int) {
        switch wmoCode {
        case 0, 1: self = .clear
        case 2: self = .partlyCloudy
        case 3: self = .cloudy
        case 45, 48: self = .fog
        case 51, 53, 55, 56, 57: self = .drizzle
        case 61, 63, 65, 66, 67, 80, 81, 82: self = .rain
        case 71, 73, 75, 77, 85, 86: self = .snow
        case 95, 96, 99: self = .thunderstorm
        default: self = .cloudy
        }
    }

    /// A short human phrase for the condition, chosen for day vs night where it
    /// matters (clear day is "Sunny", clear night is "Clear").
    nonisolated static func conditionText(wmoCode: Int, isDaytime: Bool) -> String {
        switch wmoCode {
        case 0: return isDaytime ? "Sunny" : "Clear"
        case 1: return isDaytime ? "Mostly Sunny" : "Mostly Clear"
        case 2: return "Partly Cloudy"
        case 3: return "Cloudy"
        case 45, 48: return "Fog"
        case 51, 53, 55, 56, 57: return "Drizzle"
        case 61, 63: return "Rain"
        case 65, 80, 81, 82: return "Heavy Rain"
        case 66, 67: return "Freezing Rain"
        case 71, 73, 75, 77, 85, 86: return "Snow"
        case 95, 96, 99: return "Thunderstorm"
        default: return "Cloudy"
        }
    }
}

/// The current conditions block at the top of the card.
struct WeatherCurrent: Equatable {
    let temperature: Int
    let conditionText: String
    let symbol: WeatherSymbol
    let highTemperature: Int
    let lowTemperature: Int
    /// "Feels like" (apparent) temperature, when the source reports one.
    let feelsLikeTemperature: Int?
}

/// One entry in the hourly strip.
struct WeatherHour: Equatable {
    /// "Now" for the current entry, otherwise a short hour like "4PM".
    let label: String
    let temperature: Int
    let symbol: WeatherSymbol
    let isDaytime: Bool
}

/// One entry in the multi-day forecast list.
struct WeatherDay: Equatable {
    /// "Today" for the first entry, otherwise a short weekday like "Tue".
    let label: String
    let highTemperature: Int
    let lowTemperature: Int
    let symbol: WeatherSymbol
}

/// Everything a weather card renders. Temperatures are whole degrees in the
/// unit that was requested (Fahrenheit by default); the template appends the
/// degree sign.
struct WeatherSnapshot: Equatable {
    let placeName: String
    let current: WeatherCurrent
    let hourly: [WeatherHour]
    let daily: [WeatherDay]
    /// Whether it is currently daytime at the place — drives the sky palette
    /// and the "Now" glyph.
    let isDaytime: Bool
}

// MARK: - Open-Meteo mapping

extension WeatherSnapshot {

    /// The most hourly entries a card shows (the leading "Now" plus five ahead).
    private static let maximumHourlyEntries = 6
    /// The most day entries a card shows.
    private static let maximumDailyEntries = 6

    /// Builds a snapshot from an Open-Meteo `forecast` response body plus the
    /// resolved place name.
    ///
    /// Pure and `nonisolated` so tests can drive it from a fixture with no
    /// network. `now` is injectable so the "which hours are still ahead"
    /// selection is deterministic in tests.
    nonisolated static func make(
        fromForecastJSON jsonData: Data,
        placeName: String,
        now: Date = Date()
    ) throws -> WeatherSnapshot {
        let decoder = JSONDecoder()
        let forecast = try decoder.decode(OpenMeteoForecast.self, from: jsonData)

        // All of the response's timestamps are local wall-clock for the place;
        // pin every formatter to that zone (and a fixed locale) so parsing and
        // labelling are deterministic regardless of the machine's own zone.
        let placeTimeZone = TimeZone(secondsFromGMT: forecast.utcOffsetSeconds) ?? .current
        let hourTimestampParser = makeFormatter(dateFormat: "yyyy-MM-dd'T'HH:mm", timeZone: placeTimeZone)
        let dayTimestampParser = makeFormatter(dateFormat: "yyyy-MM-dd", timeZone: placeTimeZone)
        let hourLabelFormatter = makeFormatter(dateFormat: "ha", timeZone: placeTimeZone)
        let weekdayLabelFormatter = makeFormatter(dateFormat: "EEE", timeZone: placeTimeZone)

        let isDaytime = forecast.current.isDay == 1
        let currentSymbol = WeatherSymbol(wmoCode: forecast.current.weatherCode)
        let currentTemperature = Int(forecast.current.temperature2m.rounded())
        let todaysHigh = forecast.daily.temperature2mMax.first.map { Int($0.rounded()) } ?? currentTemperature
        let todaysLow = forecast.daily.temperature2mMin.first.map { Int($0.rounded()) } ?? currentTemperature

        let current = WeatherCurrent(
            temperature: currentTemperature,
            conditionText: WeatherSymbol.conditionText(wmoCode: forecast.current.weatherCode, isDaytime: isDaytime),
            symbol: currentSymbol,
            highTemperature: todaysHigh,
            lowTemperature: todaysLow,
            feelsLikeTemperature: forecast.current.apparentTemperature.map { Int($0.rounded()) }
        )

        let hourly = mappedHourly(
            forecast: forecast,
            leadingCurrent: current,
            currentIsDaytime: isDaytime,
            currentTimestampText: forecast.current.time,
            timestampParser: hourTimestampParser,
            hourLabelFormatter: hourLabelFormatter,
            fallbackNow: now
        )
        let daily = mappedDaily(
            forecast: forecast,
            timestampParser: dayTimestampParser,
            weekdayLabelFormatter: weekdayLabelFormatter
        )

        return WeatherSnapshot(
            placeName: placeName,
            current: current,
            hourly: hourly,
            daily: daily,
            isDaytime: isDaytime
        )
    }

    /// The "Now" entry followed by the next few hours strictly after the current
    /// time, so the strip always reads forward from now.
    private nonisolated static func mappedHourly(
        forecast: OpenMeteoForecast,
        leadingCurrent: WeatherCurrent,
        currentIsDaytime: Bool,
        currentTimestampText: String,
        timestampParser: DateFormatter,
        hourLabelFormatter: DateFormatter,
        fallbackNow: Date
    ) -> [WeatherHour] {
        var hours: [WeatherHour] = [
            WeatherHour(
                label: "Now",
                temperature: leadingCurrent.temperature,
                symbol: leadingCurrent.symbol,
                isDaytime: currentIsDaytime
            )
        ]

        let currentDate = timestampParser.date(from: currentTimestampText) ?? fallbackNow
        let hourly = forecast.hourly
        var index = 0
        while index < hourly.time.count && hours.count < maximumHourlyEntries {
            defer { index += 1 }
            guard let hourDate = timestampParser.date(from: hourly.time[index]), hourDate > currentDate else { continue }
            guard index < hourly.temperature2m.count, index < hourly.weatherCode.count else { continue }
            let isDaytime = (index < hourly.isDay.count ? hourly.isDay[index] : 1) == 1
            hours.append(WeatherHour(
                label: hourLabelFormatter.string(from: hourDate),
                temperature: Int(hourly.temperature2m[index].rounded()),
                symbol: WeatherSymbol(wmoCode: hourly.weatherCode[index]),
                isDaytime: isDaytime
            ))
        }
        return hours
    }

    /// The first several days, "Today" first then short weekdays.
    private nonisolated static func mappedDaily(
        forecast: OpenMeteoForecast,
        timestampParser: DateFormatter,
        weekdayLabelFormatter: DateFormatter
    ) -> [WeatherDay] {
        let daily = forecast.daily
        let dayCount = min(
            daily.time.count,
            daily.temperature2mMax.count,
            daily.temperature2mMin.count,
            daily.weatherCode.count
        )

        var days: [WeatherDay] = []
        var index = 0
        while index < dayCount && days.count < maximumDailyEntries {
            defer { index += 1 }
            let label: String
            if index == 0 {
                label = "Today"
            } else if let dayDate = timestampParser.date(from: daily.time[index]) {
                label = weekdayLabelFormatter.string(from: dayDate)
            } else {
                label = ""
            }
            days.append(WeatherDay(
                label: label,
                highTemperature: Int(daily.temperature2mMax[index].rounded()),
                lowTemperature: Int(daily.temperature2mMin[index].rounded()),
                symbol: WeatherSymbol(wmoCode: daily.weatherCode[index])
            ))
        }
        return days
    }

    private nonisolated static func makeFormatter(dateFormat: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = dateFormat
        return formatter
    }
}

// MARK: - Open-Meteo response shapes

/// The subset of Open-Meteo's `/v1/forecast` response this feature reads.
///
/// Uses explicit `CodingKeys` for the API's snake_case (and digit-bearing) keys
/// rather than `.convertFromSnakeCase` — the automatic strategy does not map a
/// key like `temperature_2m` to `temperature2m` the way you'd expect, so being
/// explicit is the reliable choice.
private struct OpenMeteoForecast: Decodable {
    let utcOffsetSeconds: Int
    let current: Current
    let hourly: Hourly
    let daily: Daily

    enum CodingKeys: String, CodingKey {
        case utcOffsetSeconds = "utc_offset_seconds"
        case current, hourly, daily
    }

    struct Current: Decodable {
        let time: String
        let temperature2m: Double
        let apparentTemperature: Double?
        let weatherCode: Int
        let isDay: Int

        enum CodingKeys: String, CodingKey {
            case time
            case temperature2m = "temperature_2m"
            case apparentTemperature = "apparent_temperature"
            case weatherCode = "weather_code"
            case isDay = "is_day"
        }
    }

    struct Hourly: Decodable {
        let time: [String]
        let temperature2m: [Double]
        let weatherCode: [Int]
        let isDay: [Int]

        enum CodingKeys: String, CodingKey {
            case time
            case temperature2m = "temperature_2m"
            case weatherCode = "weather_code"
            case isDay = "is_day"
        }
    }

    struct Daily: Decodable {
        let time: [String]
        let weatherCode: [Int]
        let temperature2mMax: [Double]
        let temperature2mMin: [Double]

        enum CodingKeys: String, CodingKey {
            case time
            case weatherCode = "weather_code"
            case temperature2mMax = "temperature_2m_max"
            case temperature2mMin = "temperature_2m_min"
        }
    }
}
