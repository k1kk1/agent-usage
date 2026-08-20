import Foundation

/// 日別のトークン集計から「今の集計期間」を切り出す。
///
/// 利用枠（5h/7d）は API が割合を返すが、トークンは契約側の都合で期間が決まるため
/// 集計は表示側で行う。state.json には日別の内訳だけを持たせ、期間の解釈はここに寄せる。
enum TokenPeriod {
    /// state.json の日付は JST の yyyy-MM-dd。
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        return c
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func day(_ text: String?) -> Date? {
        guard let text else { return nil }
        return dayFormatter.date(from: text)
    }

    static func text(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    /// 集計期間（開始日・終了日ともに含む）。
    ///
    /// 基準日があるときは、そこから periodDays ごとに区切った周期のうち今日を含むものを返す。
    /// 基準日が未来でも過去でも同じ規則で割り出せるよう、切り捨て除算で周期番号を求める。
    /// 基準日が無いときは今日を末日とする直近 periodDays 日。
    static func range(
        plan: DisplayPreferences.TokenPlan,
        today: Date = Date()
    ) -> (start: Date, end: Date) {
        let period = max(1, plan.periodDays)
        let todayStart = calendar.startOfDay(for: today)

        guard let anchor = day(plan.anchorDate) else {
            let start = calendar.date(byAdding: .day, value: -(period - 1), to: todayStart) ?? todayStart
            return (start, todayStart)
        }

        let elapsed = calendar.dateComponents([.day], from: anchor, to: todayStart).day ?? 0
        // Swift の / は 0 方向へ丸めるため、負の側は 1 つ手前の周期に寄せる。
        let cycle = elapsed >= 0 ? elapsed / period : -((-elapsed + period - 1) / period)
        let start = calendar.date(byAdding: .day, value: cycle * period, to: anchor) ?? todayStart
        let end = calendar.date(byAdding: .day, value: period - 1, to: start) ?? start
        return (start, end)
    }

    /// 集計期間の残り日数（今日を含む）。期間の外に居るときは 0。
    static func remainingDays(
        plan: DisplayPreferences.TokenPlan,
        today: Date = Date()
    ) -> Int {
        let range = range(plan: plan, today: today)
        let todayStart = calendar.startOfDay(for: today)
        let days = calendar.dateComponents([.day], from: todayStart, to: range.end).day ?? 0
        return max(0, days + 1)
    }

    /// 集計期間に入る日を合算する。集計そのものが無い（usage が nil）ときだけ nil。
    static func bucket(
        usage: UsageState.TokenUsage?,
        plan: DisplayPreferences.TokenPlan,
        today: Date = Date()
    ) -> UsageState.TokenUsage.Bucket? {
        guard let usage else { return nil }
        let range = range(plan: plan, today: today)

        // 期間が 1 日で日別が無い場合でも、today だけは拾えるようにしておく。
        let days = usage.daily.filter { entry in
            guard let date = day(entry.date) else { return false }
            return date >= range.start && date <= range.end
        }
        if days.isEmpty {
            // 期間が 1 日で日別がまだ無い場合に備えて today も見る。
            if plan.periodDays == 1, let todayBucket = usage.today,
               day(todayBucket.date) == range.start {
                return todayBucket
            }
            // 集計自体は成功していて、その期間の記録が無いだけなら 0 として扱う。
            // 「集計できていない（usage が nil）」とは区別したいので、ここで nil は返さない。
            return zero(date: text(range.start))
        }

        let costs = days.compactMap(\.costUsd)
        return UsageState.TokenUsage.Bucket(
            date: text(range.start),
            id: nil,
            input: days.reduce(0) { $0 + $1.input },
            output: days.reduce(0) { $0 + $1.output },
            cacheWrite: days.reduce(0) { $0 + $1.cacheWrite },
            cacheRead: days.reduce(0) { $0 + $1.cacheRead },
            total: days.reduce(0) { $0 + $1.total },
            // 単価表を持たない Codex では 1 日も入らないので、その場合は出さない。
            costUsd: costs.isEmpty ? nil : costs.reduce(0, +)
        )
    }

    /// 直近 `days` 日を、記録の無い日も 0 で埋めて古い順に返す。
    /// 記録の無い日を詰めてしまうと横軸が日付として読めなくなるため、必ず埋める。
    static func dailySeries(
        usage: UsageState.TokenUsage?,
        days: Int,
        today: Date = Date()
    ) -> [(date: Date, total: Int)] {
        let todayStart = calendar.startOfDay(for: today)
        var totals: [String: Int] = [:]
        for entry in usage?.daily ?? [] {
            totals[entry.date ?? "", default: 0] += entry.total
        }
        return (0..<max(1, days)).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: todayStart) else {
                return nil
            }
            return (date, totals[text(date)] ?? 0)
        }
    }

    private static func zero(date: String) -> UsageState.TokenUsage.Bucket {
        UsageState.TokenUsage.Bucket(
            date: date,
            id: nil,
            input: 0,
            output: 0,
            cacheWrite: 0,
            cacheRead: 0,
            total: 0,
            costUsd: nil
        )
    }

    /// 割り算が暴れるので、枠をある程度使ってからでないと見積もらない。
    private static let minimumPctForEstimate: Double = 20

    /// グラフの基準線に使う「1 日あたりの目安」。
    ///
    /// 上限を設定していればそれを期間日数で割る。設定していなければ利用枠の実測から
    /// 見積もる。1 日の作業量は枠を単位に増えるので、「今日は使いすぎか」を見るには
    /// 枠 1 本ぶんが基準として扱いやすい。
    ///
    /// - 5h 枠があるなら（Claude）枠 1 本ぶんをそのまま 1 日の目安にする
    /// - 5h 枠が無いなら（Codex）7d 枠 1 本ぶんを 7 で割る
    static func dailyAllowance(
        agent: UsageState.Agent,
        plan: DisplayPreferences.TokenPlan,
        today: Date = Date()
    ) -> Int? {
        if let limit = plan.effectiveLimit {
            return limit / max(1, plan.periodDays)
        }
        if let capacity = windowCapacity(agent: agent) {
            return round2(capacity)
        }
        if let weekly = weeklyCapacity(agent: agent, today: today) {
            return round2(weekly / 7)
        }
        return nil
    }

    /// 5h 枠 1 本ぶんのトークン量。`いまの枠で使ったぶん ÷ 枠の使用率`。
    private static func windowCapacity(agent: UsageState.Agent) -> Double? {
        guard
            let recent = agent.usage?.recent5h, recent.total > 0,
            let pct = agent.orderedWindows.first(where: { $0.label == "5h" })?.usedPct,
            pct >= minimumPctForEstimate
        else { return nil }
        return Double(recent.total) / (pct / 100)
    }

    /// 7d 枠 1 本ぶんのトークン量。
    ///
    /// 7d 枠は `reset_at - 7日` が枠の開始とは限らない（使い切った時点から先の
    /// リセット時刻を返す）ため、枠内の実測では切り出せない。転がる 7 日として
    /// 直近 7 日の合計を使う。
    private static func weeklyCapacity(agent: UsageState.Agent, today: Date) -> Double? {
        guard
            let pct = agent.orderedWindows.first(where: { $0.label == "7d" })?.usedPct,
            pct >= minimumPctForEstimate
        else { return nil }
        let total = dailySeries(usage: agent.usage, days: 7, today: today)
            .reduce(0) { $0 + $1.total }
        guard total > 0 else { return nil }
        return Double(total) / (pct / 100)
    }

    /// 目安は精度より読みやすさが大事なので、上位 2 桁に丸める。
    private static func round2(_ value: Double) -> Int {
        guard value > 0 else { return 0 }
        let digits = floor(log10(value))
        let unit = pow(10, max(0, digits - 1))
        return Int((value / unit).rounded() * unit)
    }

    /// 上限に対する使用率。上限が未設定なら nil。
    static func usedPct(total: Int?, limit: Int?) -> Double? {
        guard let total, let limit, limit > 0 else { return nil }
        return Double(total) / Double(limit) * 100
    }
}
