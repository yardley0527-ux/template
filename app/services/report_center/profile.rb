# frozen_string_literal: true

module ReportCenter
  # 客群輪廓：新客 vs 舊客的年齡、縣市、消費級距，舊客另外分卡別
  class Profile < Base
    AGE_BANDS = SalesDaily::LineDigest::AGE_BANDS
    LEVELS = OrderBrief::Report::LEVELS
    SPEND_BANDS = [["未滿 $1 萬", 0...10_000], ["$1–2 萬", 10_000...20_000], ["$2–4 萬", 20_000...40_000],
                   ["$4–10 萬", 40_000...100_000], ["$10 萬以上", 100_000..]].freeze
    Person = Struct.new(:key, :email, :orders, :new_customer, keyword_init: true) do
      def amount = orders.sum(&:amount)
      def city = orders.reverse.filter_map(&:city).first
    end

    def parts
      [[:text, summary],
       tables(heading("年齡層", "新舊客各自的人數與佔比"), compare(["年齡層"], AGE_BANDS) { |p| age_band(p) },
              heading("縣市", "收件縣市；舊資料有不少沒填"), compare(["縣市"], cities) { |p| p.city || "未填" },
              heading("區間消費級距", "同一人區間內所有訂單加總"), compare(["消費"], SPEND_BANDS.map(&:first)) { |p| spend_band(p) },
              heading("舊客卡別", "目前的卡別"), level_table)]
    end

    private

    def summary
      new_people, old_people = people.partition(&:new_customer)
      lines = ["👥 #{label} 客群輪廓", *overview]
      lines << "" << "新客人均 #{money(avg(new_people))}｜舊客人均 #{money(avg(old_people))}"
      lines << "新客最多 #{top(new_people) { |p| age_band(p) }}、#{top(new_people) { |p| p.city || '未填' }}" if new_people.any?
      lines << "舊客最多 #{top(old_people) { |p| age_band(p) }}、#{top(old_people) { |p| p.city || '未填' }}" if old_people.any?
      lines.join("\n")
    end

    def avg(list) = list.empty? ? 0 : list.sum(&:amount) / list.size

    def top(list)
      name, group = list.group_by { |p| yield(p) }.reject { |k, _| %w[未知 未填].include?(k) }.max_by { |_, g| g.size }
      name ? "#{name}（#{group.size} 人）" : "資料未填"
    end

    def people
      @people ||= @data.all.group_by { |o| @data.identity.person(o.email) }.map do |key, orders|
        Person.new(key: key, email: orders.first.email, orders: orders, new_customer: orders.first.new_customer?)
      end
    end

    def compare(header, names)
      new_people, old_people = people.partition(&:new_customer)
      new_groups = new_people.group_by { |p| yield(p) }
      old_groups = old_people.group_by { |p| yield(p) }
      rows = names.filter_map do |name|
        n = new_groups.fetch(name, []).size
        o = old_groups.fetch(name, []).size
        next if n.zero? && o.zero?

        [name, n, pct(n, new_people.size), o, pct(o, old_people.size)]
      end
      table([*header, "新客", "新客佔比", "舊客", "舊客佔比"], rows)
    end

    def cities
      people.group_by { |p| p.city || "未填" }.sort_by { |name, g| [name == "未填" ? 1 : 0, -g.size] }.map(&:first)
    end

    def level_table
      old_people = people.reject(&:new_customer)
      total = old_people.sum(&:amount)
      groups = old_people.group_by { |p| @data.identity.customer(p.email)[:level] || "一般會員" }
      rows = (LEVELS | groups.keys).filter_map do |level|
        group = groups[level]
        next unless group

        amount = group.sum(&:amount)
        [level, group.size, money(amount), pct(amount, total), money(amount / group.size)]
      end
      table(["卡別", "人數", "營收", "佔舊客營收", "人均"], rows)
    end

    def spend_band(person) = SPEND_BANDS.find { |_, band| band.cover?(person.amount) }&.first

    def age_band(person)
      birthdate = @data.identity.customer(person.email)[:birthdate]
      return "未知" unless birthdate

      case @data.range.last.year - birthdate.year
      when ...20 then "20以下"
      when 20..29 then "20-29"
      when 30..39 then "30-39"
      when 40..49 then "40-49"
      when 50..59 then "50-59"
      else "60+"
      end
    end
  end
end
