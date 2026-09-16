# frozen_string_literal: true

# 「檢查方向」共用字典——WeeklyBusinessSignalClassifier（四大燈號的建議方向）
# 跟 WeeklyActionItemBuilder（下週行動清單的建議檢查方向）共用同一份，
# 內容直接取自使用者規格書第十節「各類問題的建議思考方向」，不重複定義。
module WeeklyInvestigationDirections
  BY_TOPIC = {
    "new_customer" => %w[廣告曝光 點擊率 網站訪客 到站成本 加入購物車率 結帳率 首購優惠 素材與受眾 渠道來源],
    "aov"          => %w[商品銷售組合 組合包占比 加購率 折扣幅度 高低單價商品占比 免運門檻 每單購買件數],
    "old_customer" => %w[即將用完名單 逾期天數 歷史回購次數 上次購買商品 缺貨影響 訊息送達率 召回轉換率],
    "product_inventory" => %w[預計到貨日 安全庫存 缺貨期間 受影響客群 替代商品 預購機制 到貨通知],
    "revenue"      => %w[可比較基準是否受活動高基期影響 購買人數與客單價各自貢獻 卡別結構變化 商品組合變化],
    "membership"   => %w[降級名單與降級原因 各卡別活躍率 集中度風險 升級門檻與客群]
  }.freeze

  def self.for(category)
    BY_TOPIC.fetch(category, [])
  end
end
