# frozen_string_literal: true

module ReportCenter
  # 把 email 對到「同一個人」：同 IG 的其他 email 算分身（同訂單簡報的口徑），順便帶出客人資料。
  # 只撈需要的客人，不把整張客人表搬進記憶體。
  class Identity
    IG_SQL = "ltrim(lower(trim(instagram_account)), '@')"

    def initialize(emails)
      emails = emails.compact.uniq
      @customers = {}
      @by_ig = Hash.new { |h, k| h[k] = [] }
      return if emails.empty?

      igs = ShoplineCustomer.where("lower(trim(email)) IN (?)", emails).pluck(Arel.sql(IG_SQL)).filter_map { |ig| real_ig(ig) }.uniq
      scope = ShoplineCustomer.where("lower(trim(email)) IN (?)", emails)
      scope = scope.or(ShoplineCustomer.where("#{IG_SQL} IN (?)", igs)) if igs.any?
      scope.pluck(Arel.sql("lower(trim(email))"), :full_name, :membership_level, Arel.sql(IG_SQL), :birthdate, :line_id, :order_count)
           .each do |email, name, level, ig, birthdate, line_id, order_count|
        ig = real_ig(ig)
        @customers[email] = { name: name.presence, level: level.presence, ig: ig, birthdate: birthdate,
                              line_id: line_id.presence, order_count: order_count.to_i }
        @by_ig[ig] << email if ig
      end
    end

    def customer(email) = @customers.fetch(email, {})

    def siblings(email)
      ig = customer(email)[:ig]
      ig ? ([email] + @by_ig[ig]).uniq : [email]
    end

    # 同一個人的所有 email 都回傳同一個 key
    def person(email)
      ig = customer(email)[:ig]
      ig ? "ig:#{ig}" : email
    end

    private

    # 「無」「na」這類佔位字、或誤填成 email 的都當作沒有 IG
    def real_ig(ig)
      ig.presence unless ig.nil? || OrderBrief::Report::IG_JUNK.include?(ig) || ig.include?("@")
    end
  end
end
