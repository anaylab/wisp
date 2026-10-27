//
//  WeatherSnapshotMappingTests.swift
//  leanring-buddyTests
//
//  Proves the Open-Meteo forecast body maps into a WeatherSnapshot the weather
//  card can draw — current conditions, a forward-looking hourly strip, and a
//  multi-day list — deterministically, from a checked-in fixture with no live
//  network. Also proves the data gate short-circuits before any request.
//

import XCTest
@testable import Wisp

final class WeatherSnapshotMappingTests: XCTestCase {

    // MARK: - Mapping

    func testMapsOpenMeteoForecastToSnapshot() throws {
        let forecastJSON = Data(Self.fixtureForecastJSON.utf8)

        let snapshot = try WeatherSnapshot.make(
            fromForecastJSON: forecastJSON,
            placeName: "San Francisco"
        )

        XCTAssertEqual(snapshot.placeName, "San Francisco")
        XCTAssertTrue(snapshot.isDaytime)

        // Current conditions: rounded temp, day-clear reads "Sunny", today's
        // high/low come from the first daily entry, apparent temp is carried.
        XCTAssertEqual(snapshot.current, WeatherCurrent(
            temperature: 75,
            conditionText: "Sunny",
            symbol: .clear,
            highTemperature: 75,
            lowTemperature: 58,
            feelsLikeTemperature: 78
        ))
    }

    func testHourlyStripLeadsWithNowThenFutureHours() throws {
        let snapshot = try WeatherSnapshot.make(
            fromForecastJSON: Data(Self.fixtureForecastJSON.utf8),
            placeName: "San Francisco"
        )

        // "Now" (from current) plus the five hours strictly after 3 PM.
        XCTAssertEqual(snapshot.hourly.count, 6)
        XCTAssertEqual(
            snapshot.hourly.first,
            WeatherHour(label: "Now", temperature: 75, symbol: .clear, isDaytime: true)
        )
        XCTAssertEqual(
            snapshot.hourly[1],
            WeatherHour(label: "4PM", temperature: 74, symbol: .clear, isDaytime: true)
        )
        // The 8 PM entry is after sunset (is_day 0) and its code (1) still reads
        // clear.
        XCTAssertEqual(
            snapshot.hourly.last,
            WeatherHour(label: "8PM", temperature: 66, symbol: .clear, isDaytime: false)
        )
    }

    func testDailyListLabelsTodayThenWeekdays() throws {
        let snapshot = try WeatherSnapshot.make(
            fromForecastJSON: Data(Self.fixtureForecastJSON.utf8),
            placeName: "San Francisco"
        )

        XCTAssertEqual(snapshot.daily.count, 5)
        XCTAssertEqual(
            snapshot.daily.first,
            WeatherDay(label: "Today", highTemperature: 75, lowTemperature: 58, symbol: .clear)
        )
        // 2026-09-15 is a Tuesday; code 2 is partly cloudy.
        XCTAssertEqual(
            snapshot.daily[1],
            WeatherDay(label: "Tue", highTemperature: 66, lowTemperature: 59, symbol: .partlyCloudy)
        )
        XCTAssertEqual(snapshot.daily.last?.label, "Fri")
    }

    func testMalformedForecastJSONThrows() {
        let malformed = Data("{ not a forecast }".utf8)
        XCTAssertThrowsError(
            try WeatherSnapshot.make(fromForecastJSON: malformed, placeName: "Nowhere")
        )
    }

    // MARK: - Weather symbol mapping

    func testWeatherSymbolCoversTheCodeFamilies() {
        XCTAssertEqual(WeatherSymbol(wmoCode: 0), .clear)
        XCTAssertEqual(WeatherSymbol(wmoCode: 2), .partlyCloudy)
        XCTAssertEqual(WeatherSymbol(wmoCode: 3), .cloudy)
        XCTAssertEqual(WeatherSymbol(wmoCode: 45), .fog)
        XCTAssertEqual(WeatherSymbol(wmoCode: 63), .rain)
        XCTAssertEqual(WeatherSymbol(wmoCode: 75), .snow)
        XCTAssertEqual(WeatherSymbol(wmoCode: 95), .thunderstorm)
        // An unknown code degrades to cloudy rather than crashing.
        XCTAssertEqual(WeatherSymbol(wmoCode: 999), .cloudy)
    }

    // MARK: - The data gate

    func testDisabledGateThrowsBeforeAnyNetwork() async {
        // With the gate off the provider must refuse without hitting the
        // network — the local-first opt-out.
        let provider = WeatherDataProvider()
        do {
            _ = try await provider.snapshot(
                forLocationName: "San Francisco",
                isLiveCardDataEnabled: false
            )
            XCTFail("expected a liveCardDataDisabled error")
        } catch {
            XCTAssertEqual(
                error as? WeatherDataProvider.WeatherDataError,
                .liveCardDataDisabled
            )
        }
    }

    // MARK: - Fixture

    /// A trimmed but real-shaped Open-Meteo `/v1/forecast` body for San
    /// Francisco (PDT, UTC-7) on a sunny Monday afternoon at 3 PM. Snake-case
    /// keys, as the API returns them.
    private static let fixtureForecastJSON = """
    {
      "utc_offset_seconds": -25200,
      "current": {
        "time": "2026-09-14T15:00",
        "temperature_2m": 75.1,
        "apparent_temperature": 78.4,
        "weather_code": 0,
        "is_day": 1
      },
      "hourly": {
        "time": ["2026-09-14T14:00","2026-09-14T15:00","2026-09-14T16:00","2026-09-14T17:00","2026-09-14T18:00","2026-09-14T19:00","2026-09-14T20:00"],
        "temperature_2m": [74.0, 75.0, 74.2, 72.0, 69.0, 67.0, 66.3],
        "weather_code": [0, 0, 0, 0, 0, 0, 1],
        "is_day": [1, 1, 1, 1, 1, 1, 0]
      },
      "daily": {
        "time": ["2026-09-14","2026-09-15","2026-09-16","2026-09-17","2026-09-18"],
        "weather_code": [0, 2, 2, 2, 0],
        "temperature_2m_max": [75.0, 66.0, 66.0, 68.0, 69.0],
        "temperature_2m_min": [58.0, 59.0, 60.0, 59.0, 58.0]
      }
    }
    """
}
