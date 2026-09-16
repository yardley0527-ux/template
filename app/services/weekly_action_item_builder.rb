# frozen_string_literal: true

# 「下週行動清單」——規格要求：最多5項、至少涵蓋所有紅燈（high severity）
# 旗標、依P0/P1/P2排序、每項要有具體行動與驗收KPI（不能只寫「持續觀察」）、
# 沒有實際負責人資料時給「建議負責角色」而不是猜人名。
#
# 這裡完全由程式規則產生（不經過AI），保證「所有紅燈都在清單裡」這件事
# 100%成立，不依賴AI是否乖乖照做；AI在 WeeklyBriefingService 的
# business_analysis/decisions 段落仍可以講同一批問題的敘事，但這份表格本身
# 的存在與內容不依賴AI輸出是否有效。
class WeeklyActionItemBuilder
  MAX_ITEMS = 5

  OWNER_ROLE_BY_CATEGORY = {
    "revenue"           => "營運／數據分析負責人",
    "new_customer"       => "廣告投放／成長行銷負責人",
    "old_customer"       => "CRM／客服團隊主管",
    "membership"         => "會員經營負責人",
    "product_inventory"  => "採購／供應鏈負責人",
    "data_quality"       => "資料／工程負責人"
  }.freeze

  DUE_OFFSET_DAYS = { "P0" => 7, "P1" => 10, "P2" => 14 }.freeze

  def self.call(period:, risk_flags:)
    new(period, risk_flags).call
  end

  def initialize(period, risk_flags)
    @period = period
    @flags = Array(risk_flags)
  end

  def call
    items = @flags.map { |f| build_item(f) }
    red   = items.select { |i| i[:priority] == "P0" }
    rest  = items.reject { |i| i[:priority] == "P0" }.sort_by { |i| [i[:priority] == "P1" ? 0 : 1] }

    ranked = red + rest
    # 規格「最多5項」與「至少包含所有紅燈」若真的衝突（紅燈本身就超過5項），
    # 以「至少包含所有紅燈」優先——這是使用者規格明確排的優先順序（紅燈不能
    # 被擠掉），超過5項時只補紅燈、不再補P1/P2。
    ranked = red.size >= MAX_ITEMS ? red : ranked.first(MAX_ITEMS)

    ranked.map { |i| i.except(:severity) }
  end

  private

  def build_item(flag)
    key      = (flag[:key] || flag["key"]).to_s
    category = (flag[:category] || flag["category"]).to_s
    severity = (flag[:severity] || flag["severity"]).to_s
    evidence = (flag[:evidence] || flag["evidence"] || {}).with_indifferent_access

    priority = { "high" => "P0", "medium" => "P1" }.fetch(severity, "P2")
    template = TEMPLATES[key] || generic_template(category, key)
    built = template.call(evidence)

    {
      priority: priority,
      problem: built[:problem],
      investigation_directions: built[:investigation_directions],
      action: built[:action],
      suggested_owner_role: OWNER_ROLE_BY_CATEGORY.fetch(category, "營運主管"),
      due_date: (@period.week_end + DUE_OFFSET_DAYS.fetch(priority)).to_s,
      success_metric: built[:success_metric],
      severity: severity
    }
  end

  def generic_template(category, key)
    label = WeeklyRiskFlagDetector::KEY_LABELS[key] || key
    ->(evidence) {
      if category == "data_quality"
        {
          problem: label,
          investigation_directions: [],
          action: "完成資料確認：#{label}（#{evidence.map { |k, v| "#{k}=#{v}" }.join('、')}），確認來源資料或排程是否正常後重新整理",
          success_metric: "重新產生報告後，這項資料品質檢查不再出現在風險清單裡"
        }
      else
        {
          problem: label,
          investigation_directions: WeeklyInvestigationDirections.for(category),
          action: "依「#{label}」的觸發證據（#{evidence.map { |k, v| "#{k}=#{v}" }.join('、')}）逐一排查上列檢查方向，找出根因後提出對應調整",
          success_metric: "下週同一項旗標不再觸發（回到近4週平均可接受區間內）"
        }
      end
    }
  end

  TEMPLATES = {
    "new_customer_drop_vs_avg4" => lambda do |e|
      {
        problem: "新客人數低於近4週平均#{e['drop_pct']}%（本週#{e['current']}人，近4週平均#{e['trailing4_weekly_avg']}人）",
        investigation_directions: WeeklyInvestigationDirections.for("new_customer"),
        action: "盤點近4週各拉新渠道的曝光/點擊/到站/加購/結帳各階段數字，比對本週與近4週平均，找出流失發生在哪個環節；若無明顯渠道異常，檢查首購優惠與素材是否疲乏",
        success_metric: "下週新客人數回升至近4週平均的80%以上"
      }
    end,
    "new_customer_two_consecutive_red" => lambda do |_e|
      {
        problem: "新客人數已連續兩週低於近4週平均30%以上",
        investigation_directions: WeeklyInvestigationDirections.for("new_customer"),
        action: "召開拉新渠道檢討會議，逐一檢視廣告投放/首購優惠/到站頁轉換率，兩週未改善須考慮暫停低效渠道預算並重新分配",
        success_metric: "下週新客人數止跌，較本週成長且不再觸發連續紅燈"
      }
    end,
    "overall_aov_drop_vs_avg4" => lambda do |e|
      {
        problem: "整體客單價較近4週平均下降#{e['drop_pct']}%",
        investigation_directions: WeeklyInvestigationDirections.for("aov"),
        action: "檢查本週商品銷售組合與折扣幅度，比對高單價/低單價商品占比與組合包銷售占比的變化，確認是否為促銷結構調整所致",
        success_metric: "下週整體客單價回升至近4週平均的90%以上"
      }
    end,
    "returning_customer_drop_vs_avg4" => lambda do |e|
      {
        problem: "舊客回購人數低於近4週平均#{e['drop_pct']}%",
        investigation_directions: WeeklyInvestigationDirections.for("old_customer"),
        action: "查即將用完與逾期名單的可行動人數，確認訊息是否已送達（LINE/簡訊送達率），啟動本週最值得召回的產品名單",
        success_metric: "下週舊客回購人數回升至近4週平均的80%以上"
      }
    end,
    "cohort_repurchase_rate_drop" => lambda do |e|
      {
        problem: "新客#{e['window_days']}天回購率由#{e['prev_rate_pct']}%降至#{e['current_rate_pct']}%",
        investigation_directions: WeeklyInvestigationDirections.for("old_customer"),
        action: "檢查這批新客的首購商品與上次購買商品，確認訊息送達率與召回轉換率，評估是否需要加強首購後的教育內容或回購提醒",
        success_metric: "下一個成熟cohort的回購率回升至歷史平均區間內"
      }
    end,
    "product_overdue_increasing" => lambda do |e|
      {
        problem: "「#{e['label']}」逾期未回購人數較上週成長#{e['overdue_growth_pct']}%（#{e['overdue_count_prev_week']}→#{e['overdue_count']}人）",
        investigation_directions: WeeklyInvestigationDirections.for("old_customer"),
        action: "確認「#{e['label']}」是否曾缺貨影響回購時機，並將A/B級可行動名單交付客服本週優先聯繫",
        success_metric: "下週「#{e['label']}」逾期人數增幅回落到15%以下"
      }
    end,
    "product_stockout_risk" => lambda do |e|
      {
        problem: "「#{e['label']}」缺貨中且有實質回購需求（#{Array(e['reasons']).join('、')}）",
        investigation_directions: WeeklyInvestigationDirections.for("product_inventory"),
        action: "與採購/供應鏈確認「#{e['label']}」的預計到貨日；若7天內無法確定到貨，啟動預購頁與到貨通知名單，並將受影響回購客群導向替代商品",
        success_metric: "「#{e['label']}」取得明確到貨日，或預購/到貨通知名單完成建立且開始收單"
      }
    end,
    "downgrade_exceeds_upgrade" => lambda do |e|
      {
        problem: "本週降級#{e['downgrade_count']}人多於升級#{e['upgrade_count']}人",
        investigation_directions: WeeklyInvestigationDirections.for("membership"),
        action: "調出本週降級名單，確認降級前的活躍度與最後購買商品，針對高消費力降級客群啟動客製化召回",
        success_metric: "下週升降級淨值轉正，或降級人數不再高於升級人數"
      }
    end,
    "membership_consecutive_net_downgrade" => lambda do |e|
      {
        problem: "會員升降級淨值已連續兩週為負值（本週#{e['this_week_net']}，上週#{e['prev_week_net']}）",
        investigation_directions: WeeklyInvestigationDirections.for("membership"),
        action: "檢討近兩週降級名單的共同特徵（卡別/最後購買商品/逾期天數），評估是否需要臨時會員維護活動介入",
        success_metric: "下週升降級淨值轉正，結束連續兩週淨降級"
      }
    end,
    "revenue_comparable_basis_drop" => lambda do |e|
      {
        problem: "本週營收較#{e['basis_label']}下降#{e['growth_pct'].abs rescue e['growth_pct']}%",
        investigation_directions: WeeklyInvestigationDirections.for("revenue"),
        action: "拆解本週營收下降是來自購買人數或客單價（見營收拆解區塊），並確認是否受上週活動高基期影響，避免誤判為結構性衰退",
        success_metric: "下週營收較同類型週基準回升至持平以上"
      }
    end,
    "revenue_below_required_pace" => lambda do |e|
      {
        problem: "本週營收NT$#{e['this_week_revenue'].to_i}低於達標所需週均NT$#{e['required_weekly_revenue'].to_i}，缺口#{e['shortfall_pct']}%",
        investigation_directions: WeeklyInvestigationDirections.for("revenue"),
        action: "檢視年度營收三種情境預測，評估是否需要提前規劃額外促銷或直播場次以追上達標所需週均",
        success_metric: "未來4週平均週營收回升至達標所需週均以上"
      }
    end
  }.freeze
end
