# frozen_string_literal: true

module CrmReturns
  # 匯入前一天訂單後，推到有訂閱「crm_returns」的 LINE 群組（苼莛國際-CRM優質會員）：
  # 前一天有下單、而且上一次購買已經是 GAP_DAYS 天以前的黑金卡客人，請群組跟進。
  # 上一次購買用 email 或 IG（分身）比對；資料庫裡沒有更早紀錄的不算（可能是新客直接升卡）。
  # 黑名單客人（含 IG 分身）一律排除。沒有人回來就不發（但記成檢查過）；同一天只發一次。
  # 星期一一次匯入五六日時，三天合成一份名單；隔多久以「這段期間第一次下單那天」往回算。
  class LineDigest
    TOPIC = "crm_returns"
    BLACK_GOLD = %w[黑卡 金卡].freeze
    GAP_DAYS = 180
    WEEKDAYS = %w[日 一 二 三 四 五 六].freeze
    IG_JUNK = CrmBirthdays::LineDigest::IG_JUNK

    def self.after_import
      call(LineDigestDelivery.pending_days(TOPIC, through: Date.current - 1))
    rescue StandardError => e
      Rails.logger.warn("[crm_returns] LINE 推播失敗：#{e.class}: #{e.message}")
      0
    end

    # days：一天（Date）或連續幾天（Range）
    def self.call(days, force: false)
      new(days).call(force: force)
    end

    def initialize(days, line: LineBot::Client.new)
      days = days.is_a?(Range) ? days : days..days
      @days = days.first.to_date..days.last.to_date
      @day = @days.last
      @line = line
    end

    # 回傳發送的群組數；沒設定 LINE、沒有訂閱群組、這幾天還沒匯入、沒有人回來、已發過都回 0。
    # 沒有人回來也記一筆（0 個群組），下次匯入才不會又從這幾天開始找
    def call(force: false)
      return 0 unless LineBot::Client.configured?

      groups = LineBotGroup.subscribed_to(TOPIC).to_a
      return 0 if groups.empty? || !imported?

      LineDigestDelivery.deliver_once(TOPIC, @day, force: force) do
        next 0 if returners.empty?

        push(groups)
      end
    end

    def imported? = ShoplineOrder.where(payment_status: "已付款").where("order_date::date = ?", @day).exists?

    # 沒有人回來就沒東西可發
    def pushable? = imported? && returners.any?

    # 直接發給這些群組，不看也不記「已發送」（/line_bot_groups 補發單一群組用）；回傳群組數
    def push(groups)
      texts = LineBot::Client.pack(sections)
      groups.each { |group| @line.push_texts(group.group_id, texts) }
      groups.size
    end

    def message
      sections.join("\n\n")
    end

    def sections
      head = ["🔔 久未消費的黑金卡回來了",
              "#{range_label} 訂單・上次購買已隔 #{GAP_DAYS} 天以上",
              "共 #{returners.size} 人，請跟進"]
      head << "" << "#{@days.count > 1 ? '這幾天' : '這天'}沒有符合的客人" if returners.empty?
      [head.join("\n"), *returners.map { |c| customer_block(c) }, excluded_line]
    end

    def returners
      @returners ||= begin
        rows = ShoplineCustomer.where(membership_level: BLACK_GOLD)
                               .where("lower(trim(email)) IN (?)", day_orders.keys)
                               .pluck(Arel.sql("lower(trim(email))"), :full_name, :membership_level, :total_amount, :instagram_account)
        rows.uniq(&:first).filter_map do |email, name, level, total, ig|
          ig = real_ig(ig)
          lines = day_orders[email]
          back = lines.map { |row| row[6].to_date }.min
          previous = previous_order_date(email, ig, back)
          next if previous.nil? || (back - previous) < GAP_DAYS

          if blacklist.key?(email)
            excluded << (name.presence || email)
            next
          end

          { email: email, name: name.presence || email.split("@").first, level: level, total: total.to_f, ig: ig,
            previous: previous, back: back, gap: (back - previous).to_i, lines: lines }
        end.sort_by { |c| -c[:gap] }
      end
    end

    private

    # 這幾天的已付款訂單，依 email 分組
    def day_orders
      @day_orders ||= ShoplineOrder.where(payment_status: "已付款").where("order_date::date BETWEEN ? AND ?", @days.first, @days.last)
                                   .pluck(Arel.sql("lower(trim(email))"), :order_number, :product_name, :quantity, :total_amount, :checkout_amount,
                                          Arel.sql("order_date::date"))
                                   .group_by(&:first)
                                   .except(nil, "")
    end

    def previous_order_date(email, ig, before)
      scope = ShoplineOrder.where(payment_status: "已付款").where("order_date::date < ?", before)
      scope = if ig
                scope.where("lower(trim(email)) = :email OR ltrim(lower(trim(instagram_account)), '@') = :ig", email: email, ig: ig)
              else
                scope.where("lower(trim(email)) = ?", email)
              end
      scope.maximum(:order_date)&.to_date
    end

    # 一人一個區塊；這次買的品項（同名合併數量）＋金額（整單金額只記在其中一行，取每張單的最大值再加總；
    # 整張單都沒有整單金額就用各行 checkout_amount 加總）
    def customer_block(c)
      items = c[:lines].group_by { |row| row[2].to_s.strip }.map { |name, rows| "#{name} x#{rows.sum { |r| r[3] || 1 }}" }
      amount = c[:lines].group_by { |row| row[1] }.sum do |_, rows|
        total = rows.map { |r| r[4].to_f }.max
        total.positive? ? total : rows.sum { |r| r[5].to_f }
      end
      lines = ["🖤 #{c[:name]}｜#{c[:level]}"]
      lines << "IG：#{c[:ig]}" if c[:ig]
      lines << "#{day_label(c[:back])} 回來下單" if @days.count > 1
      lines << "上次購買 #{full_date(c[:previous])}（隔 #{c[:gap]} 天）"
      lines << "這次 #{money(amount)}"
      lines += items.map { |item| "・#{item}" }
      lines << "累計 #{money(c[:total])}"
      lines.join("\n")
    end

    # 「無」「na」這類佔位字、或誤填成 email 的都當作沒有 IG
    def real_ig(ig)
      ig = ig.to_s.strip.downcase.delete_prefix("@")
      ig.presence unless IG_JUNK.include?(ig) || ig.include?("@")
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
    def range_label = @days.count > 1 ? "#{day_label(@days.first)}–#{day_label(@days.last)}" : day_label(@day)
    def full_date(date) = "#{date.year}/#{date.month}/#{date.day}"
    def money(x) = "$#{ActiveSupport::NumberHelper.number_to_delimited(x.round)}"
  end
end
