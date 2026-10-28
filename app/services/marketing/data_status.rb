# frozen_string_literal: true

module Marketing
  # 行銷機會頁上方的資料狀態：每個數字都標明資料到哪一天、從哪天開始追蹤，
  # 讓人（和 AI）知道哪些結論受資料限制。
  class DataStatus
    # Shopline 顧客匯出沒有帶行銷同意欄位（CustomersReportImporter 沒有寫入 accept_*_marketing），
    # 資料庫裡全部是預設值 false：不代表客人拒絕，也不能當作同意。
    CONSENT_NOTE = "官網顧客的行銷同意欄位沒有從 Shopline 匯入，目前全部是資料庫預設值，狀態未知（不是拒絕，也不是同意）"
    CONTACT_NOTE = "IG 私訊窗口要客人傳訊息後才開啟，系統沒有窗口狀態資料；一律顯示「待確認」，發送前請在 ManyChat 確認"

    def initialize(now: Time.current)
      @now = now
    end

    def to_h
      @to_h ||= begin
        subs = ManychatSubscriber.group(:match_status).count
        total = subs.values.sum
        types = ManychatInteraction.group(:event_type).count
        raw_sources = ManychatInteraction.where(interacted_at: (@now - 30.days)..@now).where.not(source: "").distinct.pluck(:source)
        mapped = ManychatSource.index_by_raw_name
        last_run = SyncRun.where(source: "manychat").where(status: %w[success partial]).order(:finished_at).last

        {
          manychat_last_success_at: last_run&.finished_at,
          manychat_rows_without_time: last_run&.meta&.dig("imported", "rows_without_time"),
          manychat_sync_started_on: SyncRun.where(source: "manychat").minimum(:started_at)&.to_date,
          orders_from: order_range.first, orders_to: order_range.last,
          subscribers: total,
          verified: subs["verified"].to_i, candidate: subs["candidate"].to_i, unmatched: subs["unmatched"].to_i,
          verified_rate: total.zero? ? nil : (subs["verified"].to_f / total).round(3),
          interactions_by_type: types,
          sources_30d: raw_sources.size, sources_30d_mapped: raw_sources.count { |s| mapped.key?(s) },
          flow_events: ManychatEvent.count,
          consent_note: CONSENT_NOTE, contact_note: CONTACT_NOTE
        }
      end
    end

    # 已付款訂單資料的涵蓋範圍（台北日期）
    def order_range
      @order_range ||= begin
        min, max = ShoplineOrder.where(payment_status: "已付款").pick(Arel.sql("MIN(order_date)"), Arel.sql("MAX(order_date)"))
        [min&.in_time_zone&.to_date, max&.in_time_zone&.to_date]
      end
    end

    # 給畫面與 AI 用的資料缺口說明
    def gaps
      h = to_h
      list = []
      list << "互動紀錄從 #{h[:manychat_sync_started_on]} 開始同步，之前的互動不知道；不能判定「很久沒互動」" if h[:manychat_sync_started_on]
      list << "ManyChat 訂閱者只有 #{h[:verified]}/#{h[:subscribers]} 人已確認身分，其餘人的購買狀態未知" if h[:subscribers].positive?
      list << "訂單資料只到 #{h[:orders_to]}（人工匯入），之後的下單還看不到" if h[:orders_to]
      list << "訂單只有已付款資料，沒有退款／取消，金額不是淨營收"
      list << "API 補入的互動只有最後一次，來源是補入當下的欄位值" if h[:interactions_by_type]["api_last_interaction"].to_i.positive?
      list << "最近 30 天有 #{h[:sources_30d] - h[:sources_30d_mapped]} 個來源還沒設定對應商品" if h[:sources_30d] > h[:sources_30d_mapped]
      list << "最近一次同步有 #{h[:manychat_rows_without_time]} 列試算表沒有時間" if h[:manychat_rows_without_time].to_i.positive?
      list << CONSENT_NOTE
      list
    end
  end
end
