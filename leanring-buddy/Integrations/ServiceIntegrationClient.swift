//
//  ServiceIntegrationClient.swift
//  leanring-buddy
//
//  Fetches one service's status. `ServiceIntegrationClient` does the HTTP;
//  `ServiceIntegrationResponseParser` (pure) turns each API's JSON into a
//  `ServiceIntegrationSnapshot`, so the parsing is testable with canned
//  responses. Endpoints follow Coucou's pollers (MIT), with a few more fields
//  (deploy commit messages, n8n workflow names, Resend bounces).
//

import Foundation

nonisolated enum ServiceIntegrationFetchError: LocalizedError, Equatable {
    case notConfigured
    case invalidConfiguration(String)
    case unauthorized
    case forbidden
    case httpStatus(Int)
    case network(String)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Not connected"
        case .invalidConfiguration(let reason): return reason
        case .unauthorized: return "The key was rejected (401). Check it and save it again."
        case .forbidden: return "The key doesn't have access to this (403)."
        case .httpStatus(let statusCode): return "The service answered with an error (\(statusCode))."
        case .network(let description): return description
        case .unexpectedResponse: return "The service's answer wasn't in the expected shape."
        }
    }
}

nonisolated enum ServiceIntegrationClient {
    static func fetchSnapshot(
        for kind: ServiceIntegrationKind,
        credentials: [String: String]
    ) async throws -> ServiceIntegrationSnapshot {
        switch kind {
        case .github:
            let token = credentials["token"] ?? ""
            let githubHeaders = ["Authorization": "Bearer \(token)", "Accept": "application/vnd.github+json"]
            let userData = try await getData("https://api.github.com/user", headers: githubHeaders)
            let repositoriesData = try await getData(
                "https://api.github.com/user/repos?per_page=100&affiliation=owner&sort=pushed",
                headers: githubHeaders
            )
            return try ServiceIntegrationResponseParser.githubSnapshot(userData: userData, repositoriesData: repositoriesData)

        case .vercel:
            let deploymentsData = try await getData(
                "https://api.vercel.com/v6/deployments?limit=6",
                headers: ["Authorization": "Bearer \(credentials["token"] ?? "")"]
            )
            return try ServiceIntegrationResponseParser.vercelSnapshot(deploymentsData: deploymentsData)

        case .stripe:
            let stripeHeaders = ["Authorization": "Bearer \(credentials["apiKey"] ?? "")"]
            let balanceData = try await getData("https://api.stripe.com/v1/balance", headers: stripeHeaders)
            let chargesData = try await getData("https://api.stripe.com/v1/charges?limit=5", headers: stripeHeaders)
            return try ServiceIntegrationResponseParser.stripeSnapshot(balanceData: balanceData, chargesData: chargesData)

        case .n8n:
            guard let instanceBaseURL = n8nBaseURL(from: credentials["baseURL"] ?? "") else {
                throw ServiceIntegrationFetchError.invalidConfiguration("The instance URL must start with https:// (or http://localhost).")
            }
            let n8nHeaders = ["X-N8N-API-KEY": credentials["apiKey"] ?? "", "Accept": "application/json"]
            let executionsData = try await getData("\(instanceBaseURL)/api/v1/executions?limit=6&includeData=false", headers: n8nHeaders)
            // Names make the rows readable; a failure here just leaves ids.
            let workflowsData = try? await getData("\(instanceBaseURL)/api/v1/workflows?limit=250", headers: n8nHeaders)
            return try ServiceIntegrationResponseParser.n8nSnapshot(
                executionsData: executionsData,
                workflowsData: workflowsData,
                instanceBaseURL: instanceBaseURL
            )

        case .resend:
            let emailsData = try await getData(
                "https://api.resend.com/emails?limit=10",
                headers: ["Authorization": "Bearer \(credentials["apiKey"] ?? "")"]
            )
            return try ServiceIntegrationResponseParser.resendSnapshot(emailsData: emailsData)

        case .notion:
            let searchBody: [String: Any] = [
                "sort": ["direction": "descending", "timestamp": "last_edited_time"],
                "page_size": 5,
            ]
            let searchData = try await sendRequest(
                "https://api.notion.com/v1/search",
                method: "POST",
                headers: [
                    "Authorization": "Bearer \(credentials["token"] ?? "")",
                    "Notion-Version": "2022-06-28",
                    "Content-Type": "application/json",
                ],
                body: try JSONSerialization.data(withJSONObject: searchBody)
            )
            return try ServiceIntegrationResponseParser.notionSnapshot(searchData: searchData)

        case .calcom:
            let bookingsData = try await getData(
                "https://api.cal.com/v2/bookings?status=upcoming&take=10",
                headers: ["Authorization": "Bearer \(credentials["apiKey"] ?? "")", "cal-api-version": "2024-08-13"]
            )
            return try ServiceIntegrationResponseParser.calcomSnapshot(bookingsData: bookingsData)
        }
    }

    /// The n8n instance URL without a trailing slash. HTTPS is required unless
    /// the instance is on this Mac, so the API key never crosses the network
    /// in the clear.
    static func n8nBaseURL(from rawBaseURL: String) -> String? {
        let trimmedBaseURL = rawBaseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let parsedURL = URL(string: trimmedBaseURL), let host = parsedURL.host else { return nil }
        let isLocalHost = host == "localhost" || host == "127.0.0.1"
        guard parsedURL.scheme == "https" || (parsedURL.scheme == "http" && isLocalHost) else { return nil }
        return trimmedBaseURL
    }

    private static func getData(_ urlString: String, headers: [String: String]) async throws -> Data {
        try await sendRequest(urlString, method: "GET", headers: headers, body: nil)
    }

    private static func sendRequest(_ urlString: String, method: String, headers: [String: String], body: Data?) async throws -> Data {
        guard let requestURL = URL(string: urlString) else { throw ServiceIntegrationFetchError.unexpectedResponse }
        var request = URLRequest(url: requestURL, timeoutInterval: 15)
        request.httpMethod = method
        request.httpBody = body
        for (headerName, headerValue) in headers {
            request.setValue(headerValue, forHTTPHeaderField: headerName)
        }
        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ServiceIntegrationFetchError.network(error.localizedDescription)
        }
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch statusCode {
        case 200..<300: return responseData
        case 401: throw ServiceIntegrationFetchError.unauthorized
        case 403: throw ServiceIntegrationFetchError.forbidden
        default: throw ServiceIntegrationFetchError.httpStatus(statusCode)
        }
    }
}

// MARK: - Parsing

nonisolated enum ServiceIntegrationResponseParser {
    // MARK: GitHub

    static func githubSnapshot(userData: Data, repositoriesData: Data) throws -> ServiceIntegrationSnapshot {
        guard let user = try JSONSerialization.jsonObject(with: userData) as? [String: Any],
              let repositories = try JSONSerialization.jsonObject(with: repositoriesData) as? [[String: Any]] else {
            throw ServiceIntegrationFetchError.unexpectedResponse
        }
        let publicRepositoryCount = user["public_repos"] as? Int ?? 0
        let privateRepositoryCount = user["owned_private_repos"] as? Int ?? user["total_private_repos"] as? Int ?? 0
        let totalStarCount = repositories.reduce(0) { $0 + ($1["stargazers_count"] as? Int ?? 0) }

        let recentRepositoryRows = repositories.prefix(4).compactMap { repository -> ServiceIntegrationRow? in
            guard let fullName = repository["full_name"] as? String else { return nil }
            let starCount = repository["stargazers_count"] as? Int ?? 0
            let pushedDate = (repository["pushed_at"] as? String).flatMap(parseISO8601Date)
            let detailParts = ["★ \(starCount)", pushedDate.map { "pushed \(relativeTimeText(for: $0))" }].compactMap { $0 }
            return ServiceIntegrationRow(
                id: fullName,
                title: fullName,
                detail: detailParts.joined(separator: " · "),
                tone: .neutral,
                url: (repository["html_url"] as? String).flatMap(URL.init(string:))
            )
        }
        let repositoryCount = publicRepositoryCount + privateRepositoryCount
        return ServiceIntegrationSnapshot(
            headline: "\(repositoryCount) repo\(repositoryCount == 1 ? "" : "s") · \(totalStarCount) ★",
            rows: recentRepositoryRows,
            announceableEvents: []
        )
    }

    // MARK: Vercel

    static func vercelSnapshot(deploymentsData: Data) throws -> ServiceIntegrationSnapshot {
        guard let response = try JSONSerialization.jsonObject(with: deploymentsData) as? [String: Any],
              let deployments = response["deployments"] as? [[String: Any]] else {
            throw ServiceIntegrationFetchError.unexpectedResponse
        }
        var deploymentRows: [ServiceIntegrationRow] = []
        var deploymentEvents: [ServiceIntegrationEvent] = []
        for deployment in deployments {
            guard let deploymentID = deployment["uid"] as? String,
                  let projectName = deployment["name"] as? String else { continue }
            let deploymentState = (deployment["state"] as? String) ?? (deployment["readyState"] as? String) ?? "UNKNOWN"
            let createdDate = (deployment["created"] as? Double ?? deployment["createdAt"] as? Double)
                .map { Date(timeIntervalSince1970: $0 / 1000) }
            let deploymentURL = (deployment["url"] as? String).flatMap { URL(string: "https://\($0)") }
            let metadata = deployment["meta"] as? [String: Any] ?? [:]
            let commitMessage = (metadata["githubCommitMessage"] as? String)
                ?? (metadata["gitlabCommitMessage"] as? String)
                ?? (metadata["bitbucketCommitMessage"] as? String)
            let commitSubject = commitMessage?.split(separator: "\n").first.map(String.init)

            let stateLabel = vercelStateLabel(deploymentState)
            let tone: ServiceIntegrationTone = deploymentState == "READY" ? .good : (deploymentState == "ERROR" ? .bad : .neutral)
            let detailParts = [stateLabel, createdDate.map { relativeTimeText(for: $0) }, commitSubject].compactMap { $0 }
            deploymentRows.append(ServiceIntegrationRow(
                id: deploymentID,
                title: projectName,
                detail: detailParts.joined(separator: " · "),
                tone: tone,
                url: deploymentURL
            ))

            // Only finished deploys are news; the event id carries the state so
            // a deploy seen while building is announced once it lands.
            if deploymentState == "READY" || deploymentState == "ERROR" {
                deploymentEvents.append(ServiceIntegrationEvent(
                    id: "\(deploymentID)-\(deploymentState)",
                    serviceKind: .vercel,
                    title: deploymentState == "READY" ? "Deployed \(projectName)" : "Deploy failed: \(projectName)",
                    detail: commitSubject ?? stateLabel,
                    tone: tone,
                    url: deploymentURL
                ))
            }
        }
        let headline = deploymentRows.first.map { "\($0.title) · \($0.detail.components(separatedBy: " · ").first ?? "")" }
            ?? "No deployments yet"
        return ServiceIntegrationSnapshot(headline: headline, rows: Array(deploymentRows.prefix(4)), announceableEvents: deploymentEvents)
    }

    private static func vercelStateLabel(_ deploymentState: String) -> String {
        switch deploymentState {
        case "READY": return "Ready"
        case "ERROR": return "Failed"
        case "BUILDING": return "Building"
        case "QUEUED", "INITIALIZING": return "Queued"
        case "CANCELED": return "Canceled"
        default: return deploymentState.capitalized
        }
    }

    // MARK: Stripe

    static func stripeSnapshot(balanceData: Data, chargesData: Data) throws -> ServiceIntegrationSnapshot {
        guard let balance = try JSONSerialization.jsonObject(with: balanceData) as? [String: Any],
              let chargesResponse = try JSONSerialization.jsonObject(with: chargesData) as? [String: Any],
              let charges = chargesResponse["data"] as? [[String: Any]] else {
            throw ServiceIntegrationFetchError.unexpectedResponse
        }
        let availableFunds = balance["available"] as? [[String: Any]] ?? []
        let pendingFunds = balance["pending"] as? [[String: Any]] ?? []
        let primaryCurrency = (availableFunds.first?["currency"] as? String) ?? (pendingFunds.first?["currency"] as? String) ?? "usd"
        let availableAmount = availableFunds.filter { ($0["currency"] as? String) == primaryCurrency }
            .reduce(0) { $0 + ($1["amount"] as? Int ?? 0) }
        let pendingAmount = pendingFunds.filter { ($0["currency"] as? String) == primaryCurrency }
            .reduce(0) { $0 + ($1["amount"] as? Int ?? 0) }

        var chargeRows: [ServiceIntegrationRow] = []
        var chargeEvents: [ServiceIntegrationEvent] = []
        for charge in charges {
            guard let chargeID = charge["id"] as? String,
                  let amount = charge["amount"] as? Int,
                  let currency = charge["currency"] as? String else { continue }
            let chargeStatus = charge["status"] as? String ?? ""
            let billingName = (charge["billing_details"] as? [String: Any])?["name"] as? String
            let chargeDescription = (charge["description"] as? String) ?? billingName ?? "Payment"
            let createdDate = (charge["created"] as? Double).map { Date(timeIntervalSince1970: $0) }
            let formattedAmount = formattedMoney(minorUnits: amount, currencyCode: currency)
            let didSucceed = chargeStatus == "succeeded"
            let chargeURL = URL(string: "https://dashboard.stripe.com/payments/\(chargeID)")
            chargeRows.append(ServiceIntegrationRow(
                id: chargeID,
                title: "\(formattedAmount) · \(chargeDescription)",
                detail: [didSucceed ? "Succeeded" : chargeStatus.capitalized, createdDate.map { relativeTimeText(for: $0) }]
                    .compactMap { $0 }.joined(separator: " · "),
                tone: didSucceed ? .good : (chargeStatus == "failed" ? .bad : .neutral),
                url: chargeURL
            ))
            if didSucceed || chargeStatus == "failed" {
                chargeEvents.append(ServiceIntegrationEvent(
                    id: "\(chargeID)-\(chargeStatus)",
                    serviceKind: .stripe,
                    title: didSucceed ? "New payment \(formattedAmount)" : "Payment failed · \(formattedAmount)",
                    detail: chargeDescription,
                    tone: didSucceed ? .good : .bad,
                    url: chargeURL
                ))
            }
        }
        var headline = "\(formattedMoney(minorUnits: availableAmount, currencyCode: primaryCurrency)) available"
        if pendingAmount != 0 {
            headline += " · \(formattedMoney(minorUnits: pendingAmount, currencyCode: primaryCurrency)) pending"
        }
        return ServiceIntegrationSnapshot(headline: headline, rows: chargeRows, announceableEvents: chargeEvents)
    }

    /// Stripe amounts are in the currency's smallest unit — cents, except for
    /// currencies that have none (yen, won…), where the amount is whole units.
    static func formattedMoney(minorUnits: Int, currencyCode: String) -> String {
        let zeroDecimalCurrencyCodes: Set<String> = [
            "bif", "clp", "djf", "gnf", "jpy", "kmf", "krw", "mga", "pyg", "rwf", "ugx", "vnd", "vuv", "xaf", "xof", "xpf",
        ]
        let lowercasedCurrencyCode = currencyCode.lowercased()
        let majorUnits = zeroDecimalCurrencyCodes.contains(lowercasedCurrencyCode)
            ? Double(minorUnits)
            : Double(minorUnits) / 100
        let currencyFormatter = NumberFormatter()
        currencyFormatter.numberStyle = .currency
        currencyFormatter.currencyCode = lowercasedCurrencyCode.uppercased()
        return currencyFormatter.string(from: NSNumber(value: majorUnits)) ?? "\(majorUnits) \(lowercasedCurrencyCode.uppercased())"
    }

    // MARK: n8n

    static func n8nSnapshot(executionsData: Data, workflowsData: Data?, instanceBaseURL: String) throws -> ServiceIntegrationSnapshot {
        guard let executions = dataArray(from: executionsData) else {
            throw ServiceIntegrationFetchError.unexpectedResponse
        }
        var workflowNameByID: [String: String] = [:]
        for workflow in workflowsData.flatMap(dataArray(from:)) ?? [] {
            if let workflowID = stringOrNumber(workflow["id"]), let workflowName = workflow["name"] as? String {
                workflowNameByID[workflowID] = workflowName
            }
        }

        var executionRows: [ServiceIntegrationRow] = []
        var executionEvents: [ServiceIntegrationEvent] = []
        for execution in executions {
            guard let executionID = stringOrNumber(execution["id"]) else { continue }
            let workflowID = stringOrNumber(execution["workflowId"]) ?? ""
            let workflowName = workflowNameByID[workflowID] ?? "Workflow \(workflowID)"
            let executionStatus = (execution["status"] as? String) ?? ((execution["finished"] as? Bool) == true ? "success" : "running")
            let startedDate = (execution["startedAt"] as? String).flatMap(parseISO8601Date)
            let didFail = ["error", "crashed", "failed"].contains(executionStatus)
            let executionURL = URL(string: "\(instanceBaseURL)/workflow/\(workflowID)/executions/\(executionID)")
            executionRows.append(ServiceIntegrationRow(
                id: executionID,
                title: workflowName,
                detail: [executionStatus.capitalized, startedDate.map { relativeTimeText(for: $0) }].compactMap { $0 }.joined(separator: " · "),
                tone: didFail ? .bad : (executionStatus == "success" ? .good : .neutral),
                url: executionURL
            ))
            // Workflows can run every minute; only failures are worth interrupting for.
            if didFail {
                executionEvents.append(ServiceIntegrationEvent(
                    id: executionID,
                    serviceKind: .n8n,
                    title: "Workflow failed: \(workflowName)",
                    detail: startedDate.map { "Started \(relativeTimeText(for: $0))" } ?? "",
                    tone: .bad,
                    url: executionURL
                ))
            }
        }
        let failedCount = executionRows.filter { $0.tone == .bad }.count
        let headline = executionRows.isEmpty
            ? "No runs yet"
            : (failedCount == 0 ? "Recent runs OK" : "\(failedCount) of the last \(executionRows.count) runs failed")
        return ServiceIntegrationSnapshot(headline: headline, rows: Array(executionRows.prefix(4)), announceableEvents: executionEvents)
    }

    // MARK: Resend

    static func resendSnapshot(emailsData: Data) throws -> ServiceIntegrationSnapshot {
        guard let emails = dataArray(from: emailsData) else {
            throw ServiceIntegrationFetchError.unexpectedResponse
        }
        var emailRows: [ServiceIntegrationRow] = []
        var emailEvents: [ServiceIntegrationEvent] = []
        for email in emails {
            guard let emailID = email["id"] as? String else { continue }
            let recipients = (email["to"] as? [String]) ?? ((email["to"] as? String).map { [$0] } ?? [])
            let subject = (email["subject"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(no subject)"
            let lastEvent = email["last_event"] as? String ?? ""
            let createdDate = (email["created_at"] as? String).flatMap(parseISO8601Date)
            let didBounce = lastEvent == "bounced" || lastEvent == "complained"
            emailRows.append(ServiceIntegrationRow(
                id: emailID,
                title: subject,
                detail: [recipients.first.map { "to \($0)" }, lastEvent.isEmpty ? nil : lastEvent.capitalized, createdDate.map { relativeTimeText(for: $0) }]
                    .compactMap { $0 }.joined(separator: " · "),
                tone: didBounce ? .bad : (lastEvent == "delivered" || lastEvent == "opened" || lastEvent == "clicked" ? .good : .neutral),
                url: URL(string: "https://resend.com/emails/\(emailID)")
            ))
            if didBounce {
                emailEvents.append(ServiceIntegrationEvent(
                    id: "\(emailID)-\(lastEvent)",
                    serviceKind: .resend,
                    title: lastEvent == "bounced" ? "Email bounced" : "Marked as spam",
                    detail: [subject, recipients.first].compactMap { $0 }.joined(separator: " · "),
                    tone: .bad,
                    url: URL(string: "https://resend.com/emails/\(emailID)")
                ))
            }
        }
        let bouncedCount = emailRows.filter { $0.tone == .bad }.count
        let headline = emailRows.isEmpty
            ? "No emails yet"
            : (bouncedCount == 0 ? "\(emailRows.count) recent emails, none bounced" : "\(bouncedCount) of \(emailRows.count) recent emails bounced")
        return ServiceIntegrationSnapshot(headline: headline, rows: Array(emailRows.prefix(4)), announceableEvents: emailEvents)
    }

    // MARK: Notion

    static func notionSnapshot(searchData: Data) throws -> ServiceIntegrationSnapshot {
        guard let response = try JSONSerialization.jsonObject(with: searchData) as? [String: Any],
              let results = response["results"] as? [[String: Any]] else {
            throw ServiceIntegrationFetchError.unexpectedResponse
        }
        let pageRows = results.compactMap { result -> ServiceIntegrationRow? in
            guard let pageID = result["id"] as? String else { return nil }
            let pageTitle = notionTitle(of: result)
            let iconEmoji = ((result["icon"] as? [String: Any])?["emoji"] as? String).map { "\($0) " } ?? ""
            let editedDate = (result["last_edited_time"] as? String).flatMap(parseISO8601Date)
            return ServiceIntegrationRow(
                id: pageID,
                title: iconEmoji + pageTitle,
                detail: editedDate.map { "edited \(relativeTimeText(for: $0))" } ?? "",
                tone: .neutral,
                url: (result["url"] as? String).flatMap(URL.init(string:))
            )
        }
        let headline = pageRows.first.map { "Last edit: \($0.title)" } ?? "No pages shared with Wisp"
        return ServiceIntegrationSnapshot(headline: headline, rows: pageRows, announceableEvents: [])
    }

    private static func notionTitle(of result: [String: Any]) -> String {
        // A database carries its title at the top level; a page in its title property.
        if let titleParts = result["title"] as? [[String: Any]],
           let titleText = titleParts.compactMap({ $0["plain_text"] as? String }).joined().nilIfEmpty {
            return titleText
        }
        let properties = result["properties"] as? [String: Any] ?? [:]
        for property in properties.values {
            guard let property = property as? [String: Any],
                  property["type"] as? String == "title",
                  let titleParts = property["title"] as? [[String: Any]] else { continue }
            if let titleText = titleParts.compactMap({ $0["plain_text"] as? String }).joined().nilIfEmpty {
                return titleText
            }
        }
        return "Untitled"
    }

    // MARK: Cal.com

    static func calcomSnapshot(bookingsData: Data, now: Date = Date()) throws -> ServiceIntegrationSnapshot {
        guard let bookings = dataArray(from: bookingsData) else {
            throw ServiceIntegrationFetchError.unexpectedResponse
        }
        let startDateFormatter = DateFormatter()
        startDateFormatter.setLocalizedDateFormatFromTemplate("EEE MMM d jj:mm")

        var bookingRows: [ServiceIntegrationRow] = []
        var bookingEvents: [ServiceIntegrationEvent] = []
        let upcomingBookings = bookings
            .compactMap { booking -> (booking: [String: Any], startDate: Date)? in
                guard let startDate = ((booking["start"] as? String) ?? (booking["startTime"] as? String)).flatMap(parseISO8601Date),
                      startDate > now.addingTimeInterval(-15 * 60) else { return nil }
                return (booking, startDate)
            }
            .sorted { $0.startDate < $1.startDate }
        for (booking, startDate) in upcomingBookings {
            guard let bookingID = stringOrNumber(booking["uid"]) ?? stringOrNumber(booking["id"]) else { continue }
            let bookingTitle = booking["title"] as? String ?? "Meeting"
            let firstAttendee = (booking["attendees"] as? [[String: Any]])?.first
            let attendeeName = (firstAttendee?["name"] as? String) ?? (firstAttendee?["email"] as? String)
            let startText = startDateFormatter.string(from: startDate)
            let detailText = [startText, attendeeName.map { "with \($0)" }].compactMap { $0 }.joined(separator: " · ")
            bookingRows.append(ServiceIntegrationRow(id: bookingID, title: bookingTitle, detail: detailText, tone: .neutral, url: nil))
            bookingEvents.append(ServiceIntegrationEvent(
                id: bookingID,
                serviceKind: .calcom,
                title: "New booking: \(bookingTitle)",
                detail: detailText,
                tone: .good,
                url: URL(string: "https://app.cal.com/booking/\(bookingID)")
            ))
        }
        let headline = upcomingBookings.first.map { "Next: \(($0.booking["title"] as? String) ?? "Meeting") \(relativeTimeText(for: $0.startDate, relativeTo: now))" }
            ?? "No upcoming bookings"
        return ServiceIntegrationSnapshot(headline: headline, rows: Array(bookingRows.prefix(4)), announceableEvents: bookingEvents)
    }

    // MARK: Shared

    /// Many APIs wrap their list in `{"data": [...]}`; some return the bare array.
    private static func dataArray(from responseData: Data) -> [[String: Any]]? {
        guard let jsonObject = try? JSONSerialization.jsonObject(with: responseData) else { return nil }
        if let wrappedResponse = jsonObject as? [String: Any], let wrappedList = wrappedResponse["data"] as? [[String: Any]] {
            return wrappedList
        }
        return jsonObject as? [[String: Any]]
    }

    private static func stringOrNumber(_ rawValue: Any?) -> String? {
        if let stringValue = rawValue as? String, !stringValue.isEmpty { return stringValue }
        if let numberValue = rawValue as? NSNumber { return numberValue.stringValue }
        return nil
    }

    static func parseISO8601Date(_ dateText: String) -> Date? {
        let fractionalSecondsFormatter = ISO8601DateFormatter()
        fractionalSecondsFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsedDate = fractionalSecondsFormatter.date(from: dateText) { return parsedDate }
        let plainFormatter = ISO8601DateFormatter()
        plainFormatter.formatOptions = [.withInternetDateTime]
        if let parsedDate = plainFormatter.date(from: dateText) { return parsedDate }
        // Resend writes "2024-01-01 12:00:00.000000+00".
        let spaceSeparatedFormatter = DateFormatter()
        spaceSeparatedFormatter.locale = Locale(identifier: "en_US_POSIX")
        spaceSeparatedFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZZZZZ"
        if let parsedDate = spaceSeparatedFormatter.date(from: dateText) { return parsedDate }
        spaceSeparatedFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSx"
        return spaceSeparatedFormatter.date(from: dateText)
    }

    static func relativeTimeText(for date: Date, relativeTo referenceDate: Date = Date()) -> String {
        if abs(date.timeIntervalSince(referenceDate)) < 60 { return "just now" }
        let relativeFormatter = RelativeDateTimeFormatter()
        relativeFormatter.unitsStyle = .abbreviated
        return relativeFormatter.localizedString(for: date, relativeTo: referenceDate)
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? { isEmpty ? nil : self }
}
