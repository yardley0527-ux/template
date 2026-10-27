# frozen_string_literal: true

module Manychat
  # ManyChat 新客追蹤（/manychat_leads）：期間內互動過的人，依「有沒有買、多久前互動」分群，
  # 並依來源（automation 名稱）算漏斗：互動人數 → 對到顧客 → 互動後 7 天內下單 → 營收。
  #
  # 新舊客：第一次互動前就有付款訂單的是舊客；之後才第一次下單的是「互動後成為新客」。
  # 只能用 IG 對到顧客，對不到的人一律當作還沒買。
  class LeadReport
    CONVERT_DAYS = 7
    REPLY_WINDOW = 24.hours # IG 規定：客人最後一次互動超過 24 小時就不能主動私訊
    NO_SOURCE = "（未標來源）"

    STATUSES = {
      "new_buyer"   => { label: "互動後成為新客", badge: "success", next_step: "照買的產品排回購提醒，邀請加 LINE" },
      "open"        => { label: "還沒買・24 小時內", badge: "danger",  next_step: "在 24 小時內用 ManyChat 再傳一則跟進（例如限時優惠）" },
      "closed"      => { label: "還沒買・超過 24 小時", badge: "warning", next_step: "已不能主動私訊；放進廣告再行銷，等他下次互動時依標籤推內容" },
      "existing"    => { label: "舊客", badge: "info", next_step: "依卡別給舊客話術，不送新客優惠" }
    }.freeze

    Lead = Struct.new(:subscriber, :sources, :first_at, :last_at, :status, :orders_after,
                      :amount_after, :converted, keyword_init: true) do
      def customer = subscriber.shopline_customer
    end

    attr_reader :account, :from, :to, :source

    def initialize(account:, from:, to:, source: nil, now: Time.current)
      @account = account
      @from = from
      @to = to
      @source = source.presence
      @now = now
    end

    def self.accounts
      ManychatSubscriber.distinct.order(:account_key).pluck(:account_key)
    end

    def sources
      @sources ||= ManychatInteraction.joins(:manychat_subscriber)
                                      .where(manychat_subscribers: { account_key: account })
                                      .distinct.pluck(:source).map { |s| s.presence || NO_SOURCE }.sort
    end

    def leads
      @leads ||= build_leads
    end

    def status_counts
      leads.group_by(&:status).transform_values(&:size)
    end

    # 每個來源：互動人數、對到顧客、舊客、互動後 7 天內下單人數與營收（從他第一次碰到這個來源起算，舊客下單也算）
    def funnel
      by_source = Hash.new { |h, k| h[k] = {} }
      period_interactions.each do |i|
        firsts = by_source[i.source.presence || NO_SOURCE]
        firsts[i.manychat_subscriber_id] = [firsts[i.manychat_subscriber_id], i.interacted_at].compact.min
      end
      lead_by_sub = leads.index_by { |l| l.subscriber.id }

      by_source.map do |src, firsts|
        rows = firsts.map { |sub_id, at| [lead_by_sub[sub_id], at] }
        bought = rows.map { |lead, at| orders_between(lead, at) }.reject(&:empty?)
                     .map { |os| os.sum { |o| o[:amount] } }
        { source: src, people: rows.size,
          matched: rows.count { |lead, _| lead.customer },
          existing: rows.count { |lead, _| lead.status == "existing" },
          converted: bought.size, revenue: bought.sum }
      end.sort_by { |r| -r[:people] }
    end

    private

    def period_interactions
      @period_interactions ||= begin
        scope = ManychatInteraction.joins(:manychat_subscriber)
                                   .where(manychat_subscribers: { account_key: account })
                                   .where(interacted_at: from.beginning_of_day..to.end_of_day)
        scope = scope.where(source: source == NO_SOURCE ? "" : source) if source
        scope.to_a
      end
    end

    def build_leads
      sub_ids = period_interactions.map(&:manychat_subscriber_id).uniq
      subs = ManychatSubscriber.where(id: sub_ids).includes(:shopline_customer).index_by(&:id)
      all_interactions = ManychatInteraction.where(manychat_subscriber_id: sub_ids).group_by(&:manychat_subscriber_id)
      period_by_sub = period_interactions.group_by(&:manychat_subscriber_id)
      @orders = orders_for(subs.values.filter_map(&:shopline_customer_id))

      sub_ids.map do |id|
        sub = subs[id]
        times = all_interactions[id].map(&:interacted_at)
        first_at = times.min
        last_at = [times.max, sub.last_interaction_at].compact.max
        orders = @orders[sub.shopline_customer_id] || []
        before = orders.any? { |o| o[:at] < first_at }
        after = orders.select { |o| o[:at] >= first_at }

        status = if before then "existing"
                 elsif after.any? then "new_buyer"
                 elsif @now - last_at < REPLY_WINDOW then "open"
                 else "closed"
                 end
        lead = Lead.new(subscriber: sub, first_at: first_at, last_at: last_at, status: status,
                        sources: period_by_sub[id].sort_by(&:interacted_at).map { |i| i.source.presence || NO_SOURCE }.uniq,
                        orders_after: after.size, amount_after: after.sum { |o| o[:amount] })
        lead.converted = orders_between(lead, first_at).any?
        lead
      end.sort_by { |l| [STATUSES.keys.index(l.status), -l.last_at.to_i] }
    end

    def orders_between(lead, at)
      (@orders[lead.subscriber.shopline_customer_id] || []).select { |o| o[:at] >= at && o[:at] < at + CONVERT_DAYS.days }
    end

    # 已付款訂單，一張單一筆；整單金額只記在其中一行，取最大值
    def orders_for(customer_ids)
      return {} if customer_ids.empty?

      ShoplineOrder.where(shopline_customer_id: customer_ids, payment_status: "已付款").where.not(order_date: nil)
                   .group(:shopline_customer_id, :order_number)
                   .pluck(:shopline_customer_id, Arel.sql("MIN(order_date)"), Arel.sql("MAX(total_amount)"))
                   .group_by(&:first)
                   .transform_values { |rows| rows.map { |_, at, amount| { at: at, amount: amount.to_f } } }
    end
  end
end
