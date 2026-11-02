//
//  Demo mode suite: the sample day stays believable whatever day it is, and
//  demo mode is off unless asked for at launch.
//

import Foundation

var failureCount = 0
var checkCount = 0

func check(_ condition: Bool, _ description: String) {
    checkCount += 1
    if !condition {
        failureCount += 1
        print("FAIL: \(description)")
    }
}

check(!WispDemoMode.isOn, "demo mode is off without the launch argument")
check(WispDemoMode.dataHome == FileManager.default.homeDirectoryForCurrentUser, "so every store uses the real home")
check(WispDemoMode.demoHomeURL.path.hasSuffix("Library/Application Support/Wisp Demo/home"),
      "the demo's data lives in its own folder")

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
let lateEvening = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 22, minute: 30))!

let checklist = WispDemoSampleData.checklist(now: lateEvening, calendar: calendar)
check(checklist.count == 5, "the checklist has five items")
check(Set(checklist.map(\.id)).count == checklist.count, "with distinct ids")
check(checklist.allSatisfy { $0.id.hasSuffix(":20261102") }, "keyed to the day it is shown")
check(checklist.filter(\.isCompleted).count == 1, "one is already ticked off")
check(checklist.first?.title == "Bio lab report", "the lab report comes first, as the brief says")

let snapshot = WispDemoSampleData.calendarSnapshot(now: lateEvening, calendar: calendar)
check(snapshot.events.count == 4, "four calendar events")
check(snapshot.events.allSatisfy { $0.endDate > lateEvening }, "none has ended, even late in the evening")
check(snapshot.events.map(\.startDate) == snapshot.events.map(\.startDate).sorted(), "in time order")

check(WispDemoSampleData.morningBrief.contains("Bio lab report") && WispDemoSampleData.writerPlan.contains("lab report"),
      "the Writer's plan follows the Briefer's brief")
check(WispDemoSampleData.recentAnswers.count == 3, "three recent answers")

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
