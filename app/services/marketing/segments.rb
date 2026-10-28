# frozen_string_literal: true

module Marketing
  # 行銷機會頁的客群規則。條件只能從 DEFINITIONS 的參數白名單組合，AI 與活動草稿都只能引用這裡的客群，
  # 不接受自訂條件或 SQL。改規則時要升 RULE_VERSION（草稿與 AI 快照會記下當時的版本）。
  #
  # 購買狀態分四種，未比對／候選的人一律是「未知」，不是「沒買過」：
  #   verified_purchased    已確認身分，查得到購買紀錄
  #   verified_no_purchase  已確認身分，目前訂單資料中查無購買
  #   candidate             候選比對待確認，購買狀態未知
  #   unmatched             未比對，購買狀態未知
  class Segments
    RULE_VERSION = "2026-10-29.1"
    DAYS = [7, 14, 30].freeze
    AHEAD_DAYS = [7, 14, 30].freeze
    IDENTITIES = %w[all verified candidate unmatched].freeze
    OVERDUE_DAYS = 14 # 回購：已過建議聯絡日 14 天內的也算

    PURCHASE_STATUSES = {
      "verified_purchased"   => { label: "已確認・查得到購買紀錄", known: true },
      "verified_no_purchase" => { label: "已確認・目前訂單資料查無購買", known: true },
      "candidate"            => { label: "候選待確認・購買狀態未知", known: false },
      "unmatched"            => { label: "未比對・購買狀態未知", known: false }
    }.freeze

    DEFINITIONS = {
      "recent_interactors" => {
        label: "近期互動者", params: %w[days source tag identity],
        reliability: "互動紀錄可信；購買狀態只有已確認身分的人已知"
      },
      "interacted_not_ordered" => {
        label: "已確認身分・互動後未下單", params: %w[days source],
        reliability: "只含已確認身分的人；「未下單」以目前已匯入的已付款訂單為準"
      },
      "never_purchased" => {
        label: "已確認身分・目前訂單資料查無購買", params: %w[days source],
        reliability: "只含已確認身分的人；訂單資料的起訖日以外不知道"
      },
      "product_source_interest" => {
        label: "互動來源關聯到產品", params: %w[product_key days],
        reliability: "來源與產品的關聯是人工設定，代表看過相關內容，不代表有購買需求"
      },
      "product_explicit_request" => {
        label: "明確表達產品需求", params: %w[product_key days],
        reliability: "來自 Flow 回傳的索取資訊／優惠／購買協助事件；Flow 還沒加事件前會是 0"
      },
      "repurchase_due" => {
        label: "回購機會", params: %w[product_key ahead manychat_only],
        reliability: "沿用 CRM 回購週期；週期依據分「實際資料推估」與「固定週期假設」"
      }
    }.freeze

    Result = Struct.new(:key, :params, :label, :conditions, :reliability, :members, :breakdown, keyword_init: true) do
      def count = members.size
    end

    def self.normalize_params(key, raw)
      defn = DEFINITIONS.fetch(key) { raise ArgumentError, "不支援的客群：#{key}" }
      raw = (raw || {}).to_h.stringify_keys.slice(*defn[:params])
      out = {}
      out["days"] = DAYS.include?(raw["days"].to_i) ? raw["days"].to_i : 14 if defn[:params].include?("days")
      out["ahead"] = AHEAD_DAYS.include?(raw["ahead"].to_i) ? raw["ahead"].to_i : 14 if defn[:params].include?("ahead")
      out["identity"] = raw["identity"].presence_in(IDENTITIES) || "all" if defn[:params].include?("identity")
      out["source"] = raw["source"].to_s.strip.presence if defn[:params].include?("source")
      out["tag"] = raw["tag"].to_s.strip.presence if defn[:params].include?("tag")
      out["manychat_only"] = ActiveModel::Type::Boolean.new.cast(raw["manychat_only"]) || false if defn[:params].include?("manychat_only")
      if defn[:params].include?("product_key")
        key_given = raw["product_key"].to_s.presence
        raise ArgumentError, "產品不存在：#{key_given}" if key_given && !CrmProduct.exists?(key: key_given)
        raise ArgumentError, "需要指定產品" if key_given.nil? && key != "repurchase_due"

        out["product_key"] = key_given
      end
      out.compact
    end

    def initialize(now: Time.current)
      @now = now
    end

    def build(key, raw_params = {})
      params = self.class.normalize_params(key, raw_params)
      members = send("members_#{key}", params)
      Result.new(key: key, params: params, label: DEFINITIONS[key][:label], conditions: conditions_text(key, params),
                 reliability: DEFINITIONS[key][:reliability], members: members, breakdown: breakdown(members))
    end

    # 互動來源字串 → 顯示用的來源（有設定就用設定的 key，沒有就標未對應）
    def source_label(raw)
      s = sources[raw]
      return s.name if s

      raw.present? ? "#{raw}（未設定）" : Manychat::LeadReport::NO_SOURCE
    end

    def raw_names_for(source)
      s = ManychatSource.find_by(key: source)
      s ? [s.key, *s.raw_names] : [source == Manychat::LeadReport::NO_SOURCE ? "" : source]
    end

    private

    def sources
      @sources ||= ManychatSource.index_by_raw_name
    end

    def window(days) = (@now - days.days)..@now

    def interactions(days, source: nil)
      scope = ManychatInteraction.where(interacted_at: window(days))
      scope = scope.where(source: raw_names_for(source)) if source
      scope
    end

    def subscriber_members(interaction_scope, identity: "all", tag: nil)
      grouped = interaction_scope.group_by(&:manychat_subscriber_id)
      subs = ManychatSubscriber.where(id: grouped.keys)
      subs = subs.where(match_status: identity) unless identity == "all"
      subs = subs.where("tags @> ?", [tag].to_json) if tag
      subs = subs.to_a
      orders = OrderIndex.new(subs.filter_map(&:shopline_customer_id) + subs.reject(&:verified?).flat_map(&:candidate_customer_ids))
      excluded = excluded_customer_ids(subs.filter_map(&:shopline_customer_id))

      subs.map do |sub|
        rows = grouped[sub.id].sort_by(&:interacted_at)
        member_hash(sub, orders).merge(
          "first_at_in_window" => rows.first.interacted_at.iso8601, "last_at" => rows.last.interacted_at.iso8601,
          "interactions" => rows.size, "sources" => rows.map { |r| source_label(r.source) }.uniq,
          "source_reliable" => rows.all?(&:source_reliable?),
          "excluded_reason" => (excluded[sub.shopline_customer_id] if sub.shopline_customer_id)
        )
      end.sort_by { |m| m["last_at"] }.reverse
    end

    def member_hash(sub, orders)
      status = purchase_status(sub, orders)
      { "identity_key" => "ms:#{sub.id}", "manychat_subscriber_id" => sub.id, "shopline_customer_id" => sub.shopline_customer_id,
        "ig_username" => sub.ig_username, "match_status" => sub.match_status, "purchase_status" => status,
        "manychat_status" => sub.status, "tags" => sub.tags, "contact" => "待確認" }
        .merge(candidate_hint(sub, orders))
    end

    # 候選只有一位時，附上那位顧客的訂單摘要供人工確認參考（確認前仍算「購買狀態未知」）
    def candidate_hint(sub, orders)
      return {} unless sub.match_status == "candidate" && sub.candidate_customer_ids.size == 1

      id = sub.candidate_customer_ids.first
      list = orders.orders_for(id)
      { "candidate_customer_id" => id, "candidate_orders" => list.size, "candidate_last_order_on" => list.map(&:at).max&.to_date&.iso8601 }
    end

    def purchase_status(sub, orders)
      return sub.match_status unless sub.verified?

      orders.orders_for(sub.shopline_customer_id).any? ? "verified_purchased" : "verified_no_purchase"
    end

    def members_recent_interactors(p)
      subscriber_members(interactions(p["days"], source: p["source"]), identity: p["identity"], tag: p["tag"])
    end

    # 互動後（窗口內第一次互動起）沒有已付款訂單
    def members_interacted_not_ordered(p)
      members = subscriber_members(interactions(p["days"], source: p["source"]), identity: "verified")
      orders = OrderIndex.new(members.map { |m| m["shopline_customer_id"] })
      members.reject do |m|
        first = Time.zone.parse(m["first_at_in_window"])
        orders.orders_for(m["shopline_customer_id"]).any? { |o| o.at >= first }
      end.reject { |m| m["excluded_reason"] }
    end

    def members_never_purchased(p)
      subscriber_members(interactions(p["days"], source: p["source"]), identity: "verified")
        .select { |m| m["purchase_status"] == "verified_no_purchase" }.reject { |m| m["excluded_reason"] }
    end

    def members_product_source_interest(p)
      names = sources.select { |_, s| s.product_keys.include?(p["product_key"]) }.keys
      members = subscriber_members(interactions(p["days"]).where(source: names))
      orders = OrderIndex.new(members.map { |m| m["shopline_customer_id"] })
      members.each do |m|
        m["product_purchase"] = if m["shopline_customer_id"].nil? then "unknown"
                                elsif orders.bought_product?(m["shopline_customer_id"], p["product_key"]) then "bought"
                                else "not_bought"
                                end
      end
    end

    def members_product_explicit_request(p)
      events = ManychatEvent.where(event_type: %w[info_requested offer_requested purchase_help_requested],
                                   event_time: window(p["days"]))
                            .where("properties->>'product_key' = ?", p["product_key"]).to_a
      subs = ManychatSubscriber.where(id: events.map(&:manychat_subscriber_id)).index_by(&:id)
      orders = OrderIndex.new(subs.values.filter_map(&:shopline_customer_id))
      events.group_by(&:manychat_subscriber_id).filter_map do |sub_id, evs|
        sub = subs[sub_id] or next
        member_hash(sub, orders).merge("requests" => evs.map(&:event_type).uniq, "last_at" => evs.map(&:event_time).max.iso8601)
      end
    end

    # 沿用 CRM 回購週期：目前進行中的週期、建議聯絡期在（今天 - 14 天）～（今天 + ahead）
    def members_repurchase_due(p)
      scope = CrmCustomerProductCycle.active_follow_up
                                     .where("follow_up_status IS NULL OR follow_up_status NOT IN (?)", %w[paused repurchased])
      scope = scope.where(product_key: p["product_key"]) if p["product_key"]
      today = @now.to_date
      cycles = scope.where(suggested_contact_date: (today - OVERDUE_DAYS)..(today + p["ahead"])).to_a

      customers = ShoplineCustomer.where("LOWER(TRIM(email)) IN (?)", cycles.map { |c| c.email.to_s.downcase }.uniq.presence || [""])
                                  .pluck(Arel.sql("LOWER(TRIM(email))"), :id).to_h
      excluded = excluded_customer_ids(customers.values)
      engaged = ManychatSubscriber.verified.where(shopline_customer_id: customers.values)
                                  .joins(:manychat_interactions).distinct.pluck(:shopline_customer_id).to_set
      configs = CrmRepurchaseCycleConfig.all.group_by(&:product_key)

      members = cycles.filter_map do |c|
        customer_id = customers[c.email.to_s.downcase]
        next if customer_id && excluded[customer_id]

        { "identity_key" => "email:#{c.identity_key}", "shopline_customer_id" => customer_id, "cycle_id" => c.id,
          "product_key" => c.product_key, "bottle_count" => c.bottle_count,
          "suggested_contact_date" => c.suggested_contact_date&.iso8601,
          "cycle_basis" => cycle_basis(configs[c.product_key], c.bottle_count),
          "has_manychat" => engaged.include?(customer_id), "contact" => "待確認" }
      end
      p["manychat_only"] ? members.select { |m| m["has_manychat"] } : members
    end

    # 實際資料推估：該產品＋瓶數的週期來自歷史中位數且樣本 >= 30
    def cycle_basis(configs, bottles)
      row = Array(configs).find { |c| c.bottle_count == bottles } || Array(configs).min_by { |c| (c.bottle_count - bottles.to_i).abs }
      row && row.source == "historical_median" && row.sample_size >= 30 ? "historical" : "assumption"
    end

    # 不該行銷的人：黑名單、CRM 標記不追蹤或已流失
    def excluded_customer_ids(customer_ids)
      return {} if customer_ids.empty?

      out = ShoplineCustomer.where(id: customer_ids, blacklisted: true).pluck(:id).to_h { |id| [id, "官網黑名單"] }
      CustomerProfile.where(shopline_customer_id: customer_ids)
                     .pluck(:shopline_customer_id, :blacklisted, :skip_follow_up, :churned)
                     .each do |id, black, skip, churned|
        out[id] ||= "CRM 黑名單" if black
        out[id] ||= "CRM 標記不追蹤" if skip
        out[id] ||= "CRM 標記已流失" if churned
      end
      out
    end

    def breakdown(members)
      {
        "purchase_status" => members.group_by { |m| m["purchase_status"] }.transform_values(&:size).compact,
        "product_purchase" => members.filter_map { |m| m["product_purchase"] }.tally,
        "cycle_basis" => members.filter_map { |m| m["cycle_basis"] }.tally,
        "has_manychat" => members.count { |m| m["has_manychat"] },
        "excluded" => members.count { |m| m["excluded_reason"] }
      }.reject { |_, v| v.blank? || v == 0 }
    end

    def conditions_text(key, p)
      product = p["product_key"] && CrmProduct.find_by(key: p["product_key"])&.label
      case key
      when "recent_interactors"
        ["最近 #{p['days']} 天有互動", p["source"] && "來源：#{p['source']}", p["tag"] && "標籤：#{p['tag']}",
         p["identity"] != "all" && "身分：#{ManychatSubscriber::MATCH_STATUSES.dig(p['identity'], :label)}"].compact_blank.join("・")
      when "interacted_not_ordered"
        ["已確認身分", "最近 #{p['days']} 天有互動", p["source"] && "來源：#{p['source']}", "窗口內第一次互動後沒有已付款訂單", "排除黑名單／不追蹤／已流失"].compact.join("・")
      when "never_purchased"
        ["已確認身分", "最近 #{p['days']} 天有互動", p["source"] && "來源：#{p['source']}", "目前訂單資料中沒有已付款訂單", "排除黑名單／不追蹤／已流失"].compact.join("・")
      when "product_source_interest"
        "最近 #{p['days']} 天從關聯到「#{product}」的內容入口互動（依來源設定）"
      when "product_explicit_request"
        "最近 #{p['days']} 天在 Flow 中索取「#{product}」資訊、優惠或購買協助"
      when "repurchase_due"
        [product ? "產品：#{product}" : "全部產品", "回購週期進行中、還沒回購", "建議聯絡日在過去 #{OVERDUE_DAYS} 天到未來 #{p['ahead']} 天",
         "排除暫停／已回購／黑名單／不追蹤／已流失", p["manychat_only"] && "只看有 ManyChat 互動的人"].compact.join("・")
      end
    end
  end
end
