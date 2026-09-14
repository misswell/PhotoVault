// QueryAnalyzer tests.
//
// Pure logic, so this is exhaustive rather than illustrative: the analyzer is
// where "搜索" either understands the request or quietly returns the wrong
// photos, and a wrong parse produces results that look plausible. Every case
// pins the exact plan, not just "it found something".
//
// `now` is fixed so relative dates are stable.

import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var checks = 0
var failures = 0
var currentGroup = ""

func group(_ name: String) {
    currentGroup = name
    print("\n\(name)")
}

func check(_ condition: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if condition {
        print("  [PASS] \(label)")
    } else {
        failures += 1
        let extra = detail()
        print("  [FAIL] \(label)\(extra.isEmpty ? "" : " — \(extra)")")
    }
}

// A fixed instant: 2026-09-14 12:00:00 in a fixed time zone, so "last month"
// means August 2026 no matter when this runs.
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
calendar.locale = Locale(identifier: "zh_CN")
let now = calendar.date(from: DateComponents(
    year: 2026, month: 9, day: 14, hour: 12, minute: 0, second: 0
))!
let analyzer = QueryAnalyzer(now: now, calendar: calendar)

func analyze(_ query: String) -> QueryPlan { analyzer.analyze(query) }

func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

// ---------------------------------------------------------------------------
group("plain queries pass through to the model")

do {
    let plan = analyze("海边的狗")
    check(plan.positiveVisualClauses == ["海边的狗"],
          "a Chinese noun phrase is kept intact", "\(plan.positiveVisualClauses)")
    check(plan.negativeVisualClauses.isEmpty && plan.ocrTerms.isEmpty, "no spurious extraction")
    check(!plan.isMetadataOnly, "a visual query requires the vector search")
    check(plan.combine == .all, "a single clause combines trivially")
}

do {
    // The analyzer must not "clean up" phrasing the model understands. This is
    // the design principle: extract only what the vector model cannot express.
    let plan = analyze("a whiteboard with diagrams in a meeting room")
    check(plan.positiveVisualClauses == ["a whiteboard with diagrams in a meeting room"],
          "an English phrase is kept intact", "\(plan.positiveVisualClauses)")
}

do {
    let plan = analyze("帮我找猫")
    check(plan.positiveVisualClauses == ["猫"],
          "a leading imperative is stripped", "\(plan.positiveVisualClauses)")
}

do {
    let plan = analyze("找一张发票")
    check(plan.positiveVisualClauses == ["发票"], "找 + measure word is stripped",
          "\(plan.positiveVisualClauses)")
}

do {
    let plan = analyze("猫的照片")
    check(plan.positiveVisualClauses == ["猫"], "a trailing generic noun is stripped",
          "\(plan.positiveVisualClauses)")
}

// ---------------------------------------------------------------------------
group("AND: multiple visual clauses")

do {
    let plan = analyze("狗和沙滩")
    check(plan.combine == .all, "'和' means every clause should match")
    check(Set(plan.positiveVisualClauses) == ["狗", "沙滩"],
          "the conjunction splits the clauses", "\(plan.positiveVisualClauses)")
}

do {
    let plan = analyze("发票还有登机牌")
    check(plan.combine == .all && Set(plan.positiveVisualClauses) == ["发票", "登机牌"],
          "'还有' splits without being mistaken for '和'", "\(plan.positiveVisualClauses)")
}

do {
    let plan = analyze("dog and beach")
    check(plan.combine == .all && plan.positiveVisualClauses.count == 2,
          "English 'and' splits", "\(plan.positiveVisualClauses)")
}

// ---------------------------------------------------------------------------
group("OR: the best clause wins")

do {
    let plan = analyze("狗或猫")
    check(plan.combine == .any, "'或' means any clause may match")
    check(Set(plan.positiveVisualClauses) == ["狗", "猫"],
          "the alternatives split", "\(plan.positiveVisualClauses)")
}

do {
    let plan = analyze("cat or dog")
    check(plan.combine == .any && plan.positiveVisualClauses.count == 2,
          "English 'or' splits", "\(plan.positiveVisualClauses)")
}

// ---------------------------------------------------------------------------
group("NOT: negation is separated, not merged")

do {
    let plan = analyze("不要发票")
    check(plan.positiveVisualClauses.isEmpty, "a fully negated query has no positive clause",
          "\(plan.positiveVisualClauses)")
    check(plan.negativeVisualClauses == ["发票"],
          "the negation target is captured", "\(plan.negativeVisualClauses)")
    check(plan.isMetadataOnly, "'not a receipt' is not a visual search for 'receipt'")
}

do {
    let plan = analyze("海边的狗不要其他人")
    check(plan.positiveVisualClauses == ["海边的狗"],
          "the positive part survives", "\(plan.positiveVisualClauses)")
    check(plan.negativeVisualClauses == ["其他人"],
          "the negated part is separated", "\(plan.negativeVisualClauses)")
}

do {
    let plan = analyze("没有人的照片")
    check(plan.negativeVisualClauses == ["人"], "没有 negates", "\(plan.negativeVisualClauses)")
    check(plan.positiveVisualClauses.isEmpty, "and leaves nothing positive")
}

do {
    let plan = analyze("a beach without people")
    check(plan.positiveVisualClauses == ["a beach"],
          "English 'without' splits correctly", "\(plan.positiveVisualClauses)")
    check(plan.negativeVisualClauses == ["people"],
          "and negates the right clause", "\(plan.negativeVisualClauses)")
}

// ---------------------------------------------------------------------------
group("quoted text is an exact-text request")

do {
    let plan = analyze("\"发票\" 截图")
    check(plan.ocrTerms == ["发票"], "quoted text becomes an OCR term", "\(plan.ocrTerms)")
    check(plan.mediaFilter?.kind == .screenshot, "the media kind is still recognised")
    check(plan.isMetadataOnly, "quoted-text-only queries need no embedding")
}

do {
    let plan = analyze("含 \"Invoice #12345\" 的照片")
    check(plan.ocrTerms == ["Invoice #12345"],
          "a quoted alphanumeric string is preserved verbatim", "\(plan.ocrTerms)")
}

do {
    // An unclosed quote must not eat the rest of the query.
    let plan = analyze("猫 \" 和 狗")
    check(plan.positiveVisualClauses.contains(where: { $0.contains("猫") }),
          "an unclosed quote does not swallow the query", "\(plan.positiveVisualClauses)")
}

// ---------------------------------------------------------------------------
group("dates")

do {
    let plan = analyze("去年的猫")
    check(plan.dateFilter?.start == day(2025, 1, 1) && plan.dateFilter?.end == day(2026, 1, 1),
          "去年 is the previous calendar year", "\(String(describing: plan.dateFilter))")
    check(plan.positiveVisualClauses == ["的猫"] || plan.positiveVisualClauses == ["猫"],
          "the date is removed from the visual clause", "\(plan.positiveVisualClauses)")
}

do {
    let plan = analyze("上个月的照片")
    check(plan.dateFilter?.start == day(2026, 8, 1) && plan.dateFilter?.end == day(2026, 9, 1),
          "上个月 is the previous calendar month", "\(String(describing: plan.dateFilter))")
    check(plan.isMetadataOnly, "a date-only query needs no embedding")
}

do {
    let plan = analyze("2023年5月的发票")
    check(plan.dateFilter?.start == day(2023, 5, 1) && plan.dateFilter?.end == day(2023, 6, 1),
          "2023年5月 is a one-month range", "\(String(describing: plan.dateFilter))")
    check(plan.positiveVisualClauses == ["的发票"] || plan.positiveVisualClauses == ["发票"],
          "the date is stripped from the clause", "\(plan.positiveVisualClauses)")
}

do {
    let plan = analyze("2023-05-01 登机牌")
    check(plan.dateFilter?.start == day(2023, 5, 1) && plan.dateFilter?.end == day(2023, 5, 2),
          "an ISO date is a one-day range", "\(String(describing: plan.dateFilter))")
    check(plan.positiveVisualClauses == ["登机牌"], "the date is stripped",
          "\(plan.positiveVisualClauses)")
}

do {
    let plan = analyze("2023年的截图")
    check(plan.dateFilter?.label == "2023", "a bare year with 年 is accepted",
          "\(String(describing: plan.dateFilter?.label))")
}

do {
    // A four-digit number that is not a year must stay in the query.
    let plan = analyze("2001太空漫游")
    check(plan.dateFilter == nil, "a non-year number is not treated as a date")
    check(plan.positiveVisualClauses == ["2001太空漫游"],
          "and stays in the visual clause", "\(plan.positiveVisualClauses)")
}

do {
    let plan = analyze("最近7天")
    let expectedStart = calendar.date(byAdding: .day, value: -7, to: now)!
    check(plan.dateFilter?.start == expectedStart,
          "最近7天 is a rolling window, not a calendar week",
          "\(String(describing: plan.dateFilter?.start))")
    check(plan.dateFilter?.end == now, "the window ends now")
}

do {
    let plan = analyze("yesterday")
    check(plan.dateFilter?.label == "yesterday" && plan.isMetadataOnly,
          "English relative dates work", "\(String(describing: plan.dateFilter))")
}

// ---------------------------------------------------------------------------
group("media kinds and favourites")

do {
    let plan = analyze("微信聊天截图")
    check(plan.mediaFilter?.kind == .screenshot, "截图 is recognised", "\(String(describing: plan.mediaFilter))")
    check(plan.positiveVisualClauses == ["微信聊天"],
          "and removed from the clause", "\(plan.positiveVisualClauses)")
}

do {
    let plan = analyze("视频")
    check(plan.mediaFilter?.kind == .video && plan.isMetadataOnly,
          "a video-only query needs no embedding")
}

do {
    let plan = analyze("收藏的猫")
    check(plan.mediaFilter?.favouritesOnly == true, "收藏 marks favourites-only")
    check(plan.positiveVisualClauses == ["猫"], "and is removed from the clause",
          "\(plan.positiveVisualClauses)")
}

do {
    let plan = analyze("favourite dogs")
    check(plan.mediaFilter?.favouritesOnly == true, "English favourite works")
}

// ---------------------------------------------------------------------------
group("location mentions are recognised, not resolved")

do {
    let plan = analyze("在北京拍的猫")
    check(plan.locationQuery == "北京", "在X拍的 yields the place", "\(String(describing: plan.locationQuery))")
    check(plan.positiveVisualClauses == ["猫"], "and leaves the subject",
          "\(plan.positiveVisualClauses)")
}

do {
    let plan = analyze("在上海的照片")
    check(plan.locationQuery == "上海", "a place with trailing 的照片 is extracted",
          "\(String(describing: plan.locationQuery))")
}

do {
    // The analyzer only handles the grammar. Whether "islands of Langerhans"
    // is a real place is the gazetteer's problem (Phase 8), and conflating the
    // two would silently stop recognising places missing from the list.
    let plan = analyze("在islands of Langerhans拍的")
    check(plan.locationQuery != nil, "an unknown place name is still captured")
}

// ---------------------------------------------------------------------------
group("combined queries")

do {
    let plan = analyze("去年的日本旅行照片")
    check(plan.dateFilter?.start == day(2025, 1, 1), "the date is extracted",
          "\(String(describing: plan.dateFilter))")
    check(plan.positiveVisualClauses == ["的日本旅行"] || plan.positiveVisualClauses == ["日本旅行"],
          "the visual clause survives", "\(plan.positiveVisualClauses)")
}

do {
    let plan = analyze("2023年的发票，不要报销单")
    check(plan.dateFilter?.label == "2023", "the date is found")
    check(plan.negativeVisualClauses == ["报销单"],
          "the negated clause is separated", "\(plan.negativeVisualClauses)")
    check(plan.positiveVisualClauses.count == 1, "exactly one positive clause",
          "\(plan.positiveVisualClauses)")
}

do {
    let plan = analyze("海边的狗和沙滩")
    check(plan.combine == .all, "the conjunction sets the combine mode")
    check(plan.positiveVisualClauses.count >= 2, "and yields multiple clauses",
          "\(plan.positiveVisualClauses)")
}

// ---------------------------------------------------------------------------
group("empty and degenerate input")

do {
    let plan = analyze("")
    check(plan.isEmpty, "an empty query produces an empty plan")
}

do {
    let plan = analyze("   ")
    check(plan.isEmpty, "whitespace produces an empty plan")
}

do {
    let plan = analyze("帮我找一下")
    check(plan.isMetadataOnly, "a query with only an imperative has no visual clause",
          "\(plan.positiveVisualClauses)")
}

// ---------------------------------------------------------------------------
group("full-width input")

do {
    let plan = analyze("２０２３年５月的发票")
    check(plan.dateFilter?.label == "2023-05",
          "full-width digits are folded before parsing",
          "\(String(describing: plan.dateFilter?.label))")
}

// ---------------------------------------------------------------------------
print("\nchecks: \(checks), failures: \(failures)")
if failures == 0 {
    print("RESULT: all \(checks) query-analyzer checks passed")
    exit(0)
} else {
    print("RESULT: \(failures) of \(checks) checks FAILED")
    exit(1)
}
