# frozen_string_literal: true

module AdsWeekly
  # 廣告週報（報告中心複製貼 LINE 群）：week_end 往前 7 天跟上一週比。
  # - 營收／新客：OrderBrief::Report（同訂單簡報口徑）
  # - Chloe 新追蹤：ManyChat「新追蹤」（10/27 起才有紀錄；退追不會記，只算增加）
  # - 粉絲淨增：IG 粉絲數（本機 script／Graph API）週末減上週末，缺日期就寫待補
  # - Meta 花費、廣告追蹤、單一廣告重點：ad_weekly_metrics（Claude 用 Meta 連接器每週填）
  class Digest
    CHLOE = "chloechao0527"
    OFFICIAL = "shengting_official"
    FOLLOW_SOURCE = "新追蹤"
    COST_CAP = 120 # 11/3 定的每位追蹤成本上限

    attr_reader :week, :prev_week

    def initialize(week_end)
      @week = (week_end - 6)..week_end
      @prev_week = (week_end - 13)..(week_end - 7)
    end

    def label(range = week) = "#{range.first.month}/#{range.first.day}–#{range.last.month}/#{range.last.day}"

    def message
      [
        "📣 廣告週報｜#{label}",
        section("💰 營收與新客", sales_lines),
        section("📸 IG 追蹤", follow_lines),
        section("📊 Meta 廣告", meta_lines),
        (section("🎬 #{focus_title}", meta.notes.map { |n| "・#{n}" }) if meta&.notes.present?)
      ].compact.join("\n\n")
    end

    private

    def section(title, lines) = (["━━ #{title} ━━"] + lines).join("\n")

    def sales_lines
      cur, prev = summary(week), summary(prev_week)
      ["營收 #{wan(cur[:revenue])}（上週 #{wan(prev[:revenue])}）",
       "新客 #{cur[:new_people]} 人・新客營收 #{wan(cur[:new_revenue])}（佔 #{cur[:new_share]}%）",
       "上週新客 #{prev[:new_people]} 人・#{wan(prev[:new_revenue])}"]
    end

    def follow_lines
      cur, prev = follows(week), follows(prev_week)
      change = prev.positive? ? "，#{pct(cur, prev)}" : ""
      chloe_net, official_net = net(CHLOE), net(OFFICIAL)
      pending = [chloe_net, official_net].any?(&:nil?) ? "（待補）" : ""
      ["Chloe 新追蹤 #{cur} 人（上週 #{prev}#{change}）",
       "Chloe 粉絲淨增 #{signed(chloe_net)}・官方 IG 粉絲淨增 #{signed(official_net)}#{pending}",
       "追蹤後首購（對得到 IG 的）：本週 #{followed_new_customers} 人"]
    end

    def meta_lines
      return ["（這週的 Meta 數字還沒填）"] unless meta

      cur_new = summary(week)[:new_people]
      lines = ["花費 #{money(meta.spend)}#{"（上週 #{money(prev_meta.spend)}）" if prev_meta}"]
      if meta.ad_follows.positive?
        cost = (meta.spend.to_f / meta.ad_follows).round
        lines << "廣告帶來追蹤 #{meta.ad_follows}・每位 #{money(cost)}（上限 #{money(COST_CAP)}）#{'⚠️' if cost > COST_CAP}"
      end
      if cur_new.positive?
        prev_new = summary(prev_week)[:new_people]
        prev_cost = "（上週 #{money(prev_meta.spend.to_f / prev_new)}）" if prev_meta && prev_new.positive?
        lines << "廣告費÷新客 #{money(meta.spend.to_f / cur_new)}#{prev_cost}"
      end
      lines
    end

    def focus_title = "心路歷程"

    def meta = @meta ||= AdWeeklyMetric.for_week(week.last)
    def prev_meta = @prev_meta ||= AdWeeklyMetric.for_week(prev_week.last)

    def summary(range) = (@summaries ||= {})[range] ||= report(range).summary
    def report(range) = (@reports ||= {})[range] ||= OrderBrief::Report.new(range)

    def follows(range)
      ManychatSubscriber.where(account_key: CHLOE, source: FOLLOW_SOURCE, subscribed_at: taiwan_times(range)).count
    end

    def taiwan_times(range)
      zone = ActiveSupport::TimeZone["Asia/Taipei"]
      zone.local(range.first.year, range.first.month, range.first.day)...zone.local(range.last.year, range.last.month, range.last.day) + 1.day
    end

    # 週末粉絲數 − 上週末粉絲數；任一天沒資料就回 nil
    def net(account)
      series = (@ig ||= IgFollowerSnapshot.merged_data)[account].to_a.to_h { |e| [e["date"], e["followers"]] }
      now, before = series[week.last.to_s], series[prev_week.last.to_s]
      now && before ? now - before : nil
    end

    # 本週新客裡，IG 帳號在 ManyChat「新追蹤」名單、而且追蹤早於本週結束的人數（最少值：只算對得到 IG 的）
    def followed_new_customers
      emails = report(week).rows.select(&:new_customer?).map(&:email)
      return 0 if emails.empty?

      igs = ShoplineCustomer.where(email: emails).pluck(:instagram_account).filter_map { |ig| normalize_ig(ig) }.uniq
      return 0 if igs.empty?

      ManychatSubscriber.where(account_key: CHLOE, source: FOLLOW_SOURCE, ig_username: igs)
                        .where(subscribed_at: ...taiwan_times(week).end).distinct.count(:ig_username)
    end

    def normalize_ig(raw)
      ig = raw.to_s.strip.downcase.sub(%r{\A.*instagram\.com/}, "").delete("@").split(/[\/?]/).first.to_s
      ManychatSubscriber.valid_ig?(ig) ? ig : nil
    end

    def wan(amount) = "#{(amount.to_f / 10_000).round(1)} 萬"
    def money(n) = "$#{delimit(n.round)}"
    def signed(n) = n.nil? ? "—" : "#{n.negative? ? '−' : '+'}#{delimit(n.abs)}"
    def delimit(n) = ActiveSupport::NumberHelper.number_to_delimited(n)
    def pct(cur, prev) = format("%+d%%", ((cur - prev) * 100.0 / prev).round).sub("-", "−")
  end
end
