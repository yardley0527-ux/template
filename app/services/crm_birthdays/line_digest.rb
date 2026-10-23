# frozen_string_literal: true

module CrmBirthdays
  # 每週一推到有訂閱「crm_birthdays」的 LINE 群組（苼莛國際-CRM優質會員）：
  # 1. 本週（週一到週日）生日的黑金卡客人
  # 2. 特別關注：接下來 3 週生日、累計消費 ≥ HIGH_SPEND 的非黑金卡客人
  # 黑名單客人（含 IG 分身）一律排除，訊息最後寫排除了誰。
  # 由 seo:daily（Render Cron 台灣 10:00）在週一順便呼叫；同一週只發一次。
  class LineDigest
    TOPIC = "crm_birthdays"
    BLACK_GOLD = %w[黑卡 金卡].freeze
    HIGH_SPEND = 50_000 # 累計消費門檻（shopline_customers.total_amount）
    WATCH_DAYS = 21
    WEEKDAYS = %w[日 一 二 三 四 五 六].freeze
    SHORT_LEVEL = { "黑卡" => "黑", "金卡" => "金", "銀卡" => "銀", "白卡" => "白" }.freeze

    def self.call(today = Date.current, force: false)
      new(today).call(force: force)
    end

    def initialize(today, line: LineBot::Client.new)
      @week_start = today.to_date.beginning_of_week
      @line = line
    end

    def call(force: false)
      return 0 unless LineBot::Client.configured?

      groups = LineBotGroup.subscribed_to(TOPIC).to_a
      return 0 if groups.empty?

      LineDigestDelivery.deliver_once(TOPIC, @week_start, force: force) do
        texts = LineBot::Client.pack(sections)
        groups.each { |group| @line.push_texts(group.group_id, texts) }
        groups.size
      end
    end

    def message
      sections.join("\n\n")
    end

    # 黑金卡、特別關注、黑名單各一段；名單長時 LINE 會拆成多則
    def sections
      week_end = @week_start + 6
      black_gold = birthdays(@week_start..week_end).select { |c| BLACK_GOLD.include?(c[:level]) }
      watch = birthdays(@week_start..(@week_start + WATCH_DAYS - 1))
              .reject { |c| BLACK_GOLD.include?(c[:level]) }
              .select { |c| c[:total] >= HIGH_SPEND }

      first = ["🎂 生日名單 #{day_label(@week_start)}–#{day_label(week_end)}", "", "【黑金卡本週生日】#{black_gold.size} 人"]
      first += black_gold.any? ? black_gold.map { |c| customer_line(c) } : ["本週沒有黑金卡客人生日"]

      second = ["【特別關注】非黑金卡、累計消費 #{money(HIGH_SPEND)} 以上，接下來 3 週生日（到 #{day_label(@week_start + WATCH_DAYS - 1)}）#{watch.size} 人"]
      second += watch.any? ? watch.map { |c| customer_line(c) } : ["接下來 3 週沒有符合的客人"]

      [first.join("\n"), second.join("\n"), excluded_line]
    end

    private

    # 生日用月日比對（跨月、跨年都對）；依生日先後排序
    def birthdays(range)
      @birthdays ||= {}
      @birthdays[range] ||= begin
        days = range.to_a
        conditions = days.map { |d| "(EXTRACT(month FROM birthdate) = #{d.month} AND EXTRACT(day FROM birthdate) = #{d.day})" }.join(" OR ")
        rows = ShoplineCustomer.where.not(birthdate: nil).where(conditions)
                               .pluck(Arel.sql("lower(trim(email))"), :full_name, :membership_level, :birthdate, :total_amount, :instagram_account)
        customers = rows.filter_map do |email, name, level, birthdate, total, ig|
          next if email.blank?
          if blacklist.key?(email)
            excluded << (name.presence || email)
            next
          end

          date = days.find { |d| d.month == birthdate.month && d.day == birthdate.day }
          { email: email, name: name.presence || email.split("@").first, level: level.presence || "一般會員",
            date: date, total: total.to_f, ig: ig.to_s.strip.presence }
        end.uniq { |c| c[:email] }
        attach_last_order(customers).sort_by { |c| [c[:date], -c[:total]] }
      end
    end

    def attach_last_order(customers)
      last = ShoplineOrder.where(payment_status: "已付款")
                          .where("lower(trim(email)) IN (?)", customers.map { |c| c[:email] })
                          .group(Arel.sql("lower(trim(email))")).maximum(:order_date)
      customers.each { |c| c[:last_order] = last[c[:email]]&.to_date }
    end

    def customer_line(c)
      parts = ["・#{day_label(c[:date])} #{c[:name]}（#{SHORT_LEVEL.fetch(c[:level], '一般')}）"]
      parts << "IG #{c[:ig]}" if c[:ig] && !%w[無 na no n/a none - 沒有 x .].include?(c[:ig].downcase)
      parts << "累計 #{money(c[:total])}"
      parts << (c[:last_order] ? "最近購買 #{c[:last_order].strftime('%Y/%-m/%-d')}" : "沒有購買紀錄")
      parts.join("｜")
    end

    def excluded_line
      names = excluded.uniq
      names.any? ? "已排除黑名單 #{names.size} 人（#{names.join('、')}）" : "已檢查黑名單，0 人命中"
    end

    def blacklist
      @blacklist ||= MessageListBuilder.blacklisted_emails
    end

    def excluded
      @excluded ||= []
    end

    def day_label(date) = "#{date.month}/#{date.day}（#{WEEKDAYS[date.wday]}）"
    def money(x) = "$#{ActiveSupport::NumberHelper.number_to_delimited(x.round)}"
  end
end
