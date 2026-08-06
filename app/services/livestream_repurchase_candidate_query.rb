# frozen_string_literal: true

# 一場直播的回購候選名單。候選人只從 Phase 2/3 的 active task 取得，
# 不重新解析 shopline_orders 歷史——直播用的產品（livestream.product_keys，
# 沿用既有欄位，沒有另建關聯表）決定要看哪些 cycle。
#
# 候選原因（reason）：
#   - replenish：預估用完日落在直播日 ±14 天內
#   - win_back_1_30 / win_back_31_60 / win_back_61_90：以直播日為基準，
#     逾期天數落在對應區間（61_90 的上限是 WIN_BACK_MAX_DAYS，可調整，
#     單一設定值，不散落在多處）
#   - dormant_over_90：逾期超過 WIN_BACK_MAX_DAYS，預設不進入候選名單，
#     只能靠明確篩選查看，但一律會被算出來、不會消失
#   - related_product：MVP 預設關閉，見 RELATED_PRODUCT_MAP 註解
#
# ── Phase 3.1 時間穿越修正 ──────────────────────────────────────────
# 過去的直播（livestream.date < 今天）不能直接用「現在」的 active_follow_up
# 回推當時名單：那會讓直播之後才發生的訂單/聯絡/回購污染歷史狀態。改用
# CrmCustomerProductCycle.active_as_of(livestream.date)（只看直播當天以前
# 已存在、當時仍有效的週期），並且用 CrmCustomerProductFollowUpEvent 歷史
# 重建「直播當天已知」的 follow_up_status/last_contacted_at——這個重建只看
# 「最後一筆非 note_only 事件」，不是完整狀態機回放（not_yet_finished 給
# remaining_days 或 next_contact_date 的分支無法從事件本身分辨），所以歷史
# 場次一律視為「歷史推估名單」，不宣稱是當時實際存檔的名單。
#
# 未來／今天的直播直接用現在的即時資料（active_follow_up + cycle 目前欄位），
# 完全準確，不受這個限制。
class LivestreamRepurchaseCandidateQuery
  PER_PAGE = 20
  REPLENISH_WINDOW_DAYS = 14
  RECENTLY_CONTACTED_DAYS = 7

  # 唯一的「幾天算沉睡客」設定來源——頁面 query param `win_back_max_days`
  # 沒帶的話用這個預設值，不要在別的檔案重複寫 90 這個數字。
  DEFAULT_WIN_BACK_MAX_DAYS = 90

  RELATED_PRODUCT_MAP = {}.freeze # product_key => [related product_key, ...]；MVP 空，見上方註解

  REASON_LABELS = {
    "replenish"       => "即將用完（直播日±14天）",
    "win_back_1_30"   => "近期流失（逾期1–30天）",
    "win_back_31_60"  => "中度流失（逾期31–60天）",
    "win_back_61_90"  => "高風險流失（逾期61天以上）",
    "dormant_over_90" => "歷史沉睡客",
    "related_product" => "關聯產品"
  }.freeze

  REASON_PRIORITY = {
    "replenish"       => 1,
    "win_back_1_30"   => 2,
    "win_back_31_60"  => 3,
    "win_back_61_90"  => 4,
    "dormant_over_90" => 5,
    "related_product" => 6
  }.freeze

  DORMANT_REASON = "dormant_over_90"

  CandidateRow = Struct.new(:identity_key, :hits, :representative_cycle, :reference_date, keyword_init: true) do
    def cycles
      @cycles ||= hits.map { |h| h[:cycle] }.uniq(&:id)
    end

    def reasons
      hits.map { |h| h[:reason] }.uniq
    end

    def hit_product_keys
      hits.map { |h| h[:product_key] }.uniq
    end

    # 相對於這次查詢的參考日（直播日）算，不是 cycle#effective_remaining_days
    # （那個方法內部固定用 Date.current，歷史場次會算錯）。
    def remaining_days
      (representative_cycle.effective_finish_date - reference_date).to_i
    end

    def overdue_days
      d = remaining_days
      d.negative? ? -d : 0
    end

    def derived_status
      return representative_cycle.follow_up_status if representative_cycle.follow_up_status.present?

      days = remaining_days
      return "overdue"   if days.negative?
      return "due_today" if days.zero?
      return "due_soon"  if days <= CrmCustomerProductCycle::DUE_SOON_DAYS

      "tracking"
    end

    def best_reason_priority
      reasons.map { |r| LivestreamRepurchaseCandidateQuery::REASON_PRIORITY[r] || 99 }.min
    end
  end

  def initialize(livestream, params = {})
    @livestream        = livestream
    @reason            = params[:reason].presence
    @product_key       = params[:product_key].presence
    @status            = params[:status].presence
    @assigned_to       = params[:assigned_to].presence
    @q                 = params[:q].to_s.strip.presence
    @page              = [params[:page].to_i, 1].max
    @win_back_max_days = (params[:win_back_max_days].presence || DEFAULT_WIN_BACK_MAX_DAYS).to_i
  end

  def historical?
    @livestream.date < Date.current
  end

  # 過去場次一律視為推估，不宣稱是當時實際存檔的名單（見檔案頂端註解）。
  def estimate_disclaimer_needed?
    historical?
  end

  def reference_date
    @livestream.date
  end

  def candidate_rows
    @candidate_rows ||= filtered_rows
  end

  def page_rows
    @page_rows ||= candidate_rows[((page - 1) * PER_PAGE), PER_PAGE] || []
  end

  def total_count
    candidate_rows.size
  end

  def total_pages
    [(total_count.to_f / PER_PAGE).ceil, 1].max
  end

  def page
    [@page, total_pages].min
  end

  # 缺週期設定的產品——這些產品的顧客不會出現在候選名單裡，不是被篩掉，
  # 是根本沒有 cycle 可以看，所以「排除且可計數」。
  def products_missing_cycle_config
    return @products_missing_cycle_config if defined?(@products_missing_cycle_config)

    configured = CrmRepurchaseCycleConfig.where(product_key: @livestream.product_keys).distinct.pluck(:product_key)
    missing_keys = @livestream.product_keys - configured
    labels = CrmProduct.where(key: missing_keys).pluck(:key, :label).to_h
    @products_missing_cycle_config = missing_keys.map { |k| { product_key: k, label: labels[k] || k } }
  end

  # 直播摘要數字（Phase 3.1 新增）：跟預設列表用同一份 all_rows，數字一定對得起來。
  def summary_counts
    rows = all_rows
    {
      replenish:        rows.count { |r| r.reasons.include?("replenish") },
      win_back_1_30:     rows.count { |r| r.reasons.include?("win_back_1_30") },
      win_back_31_60:    rows.count { |r| r.reasons.include?("win_back_31_60") },
      win_back_61_90:    rows.count { |r| r.reasons.include?("win_back_61_90") },
      dormant_over_90:   rows.count { |r| r.reasons.include?(DORMANT_REASON) },
      default_actionable: rows.count { |r| default_visible?(r) }
    }
  end

  # 這場直播的 follow-up event 執行結果（明確只看有 livestream_id 關聯的操作歷史，
  # 不是全站統計）。範圍是「預設可執行名單」（跟 summary_counts 的
  # default_actionable 同一群），不含歷史沉睡客——不然 not_yet_handled 會把
  # 幾千個根本不在待辦流程裡的沉睡客也算進去，數字會比 total_count 大很多倍。
  def kpis
    rows = all_rows.select { |r| default_visible?(r) }
    {
      contacted:        rows.count { |r| r.representative_cycle.last_contacted_at.present? },
      waiting_reply:    rows.count { |r| r.representative_cycle.follow_up_status == "waiting_reply" },
      repurchased:      repurchased_via_this_livestream_count,
      not_yet_handled:  rows.count { |r| r.representative_cycle.follow_up_status.nil? }
    }
  end

  private

  def default_visible?(row)
    (row.reasons - [DORMANT_REASON]).any?
  end

  # 「已回購」是這場直播帶來的成果，來源是 follow_up_events 歷史（有
  # livestream_id 關聯），不是現在的候選池——一旦標記已回購，那個人就被
  # 排除規則踢出候選池了，用候選池自己算永遠是 0。
  def repurchased_via_this_livestream_count
    CrmCustomerProductFollowUpEvent
      .where(livestream_id: @livestream.id, action: "repurchased")
      .joins(:cycle)
      .distinct
      .count("crm_customer_product_cycles.identity_key")
  end

  def all_rows
    @all_rows ||= group_into_rows(build_hits)
  end

  def filtered_rows
    rows = all_rows

    rows = if @reason.present?
      rows.select { |r| r.reasons.include?(@reason) }
    else
      rows.select { |r| default_visible?(r) }
    end

    rows = rows.select { |r| r.hit_product_keys.include?(@product_key) } if @product_key
    rows = rows.select { |r| r.derived_status == @status } if @status
    rows = rows.select { |r| r.representative_cycle.assigned_to_user_id.to_s == @assigned_to } if @assigned_to
    rows = apply_search(rows) if @q

    rows.sort_by { |r| [r.best_reason_priority, r.remaining_days] }
  end

  def apply_search(rows)
    like = "%#{@q}%"
    matching_emails = ShoplineCustomer
      .where("full_name ILIKE :q OR mobile_phone ILIKE :q OR email ILIKE :q", q: like)
      .limit(500).pluck(:email).to_set

    rows.select do |r|
      email = r.representative_cycle.email
      email&.include?(@q) || matching_emails.include?(email)
    end
  end

  def group_into_rows(hits)
    hits.group_by { |h| h[:cycle].identity_key }.map do |identity_key, group_hits|
      representative = group_hits.map { |h| h[:cycle] }.uniq(&:id)
        .min_by { |c| (c.effective_finish_date - @livestream.date).to_i }

      CandidateRow.new(identity_key: identity_key, hits: group_hits,
                        representative_cycle: representative, reference_date: @livestream.date)
    end
  end

  # ── 候選 cycle 取得（現在 vs 歷史分支）──────────────────────────────

  def eligible_cycles
    @eligible_cycles ||= begin
      base = if historical?
        CrmCustomerProductCycle.active_as_of(@livestream.date)
      else
        CrmCustomerProductCycle.active_follow_up
      end

      cycles = base.where(product_key: @livestream.product_keys).includes(:assigned_to).to_a

      if historical?
        apply_historical_state!(cycles)
      end

      cycles.select { |c| passes_contact_and_status_exclusions?(c) }
    end
  end

  # 直接把重建出來的「直播當天已知」狀態覆寫進記憶體中的 cycle 物件（不落地存檔）
  # ——這樣後面所有讀 cycle.follow_up_status/last_contacted_at 的地方（排除規則、
  # KPI、畫面顯示）都自動使用歷史推估值，不用另外做一套平行邏輯。
  def apply_historical_state!(cycles)
    states = historical_states_for(cycles.map(&:id))
    cycles.each do |cycle|
      state = states[cycle.id] || {}
      cycle.follow_up_status  = state[:follow_up_status]
      cycle.last_contacted_at = state[:last_contacted_at]
      cycle.next_contact_date = state[:next_contact_date]
    end
  end

  # 兩條查詢，依 cycle_id 批次取得「直播當天以前最後一次事件」，不是逐 cycle 查
  # （避免 N+1）。note_only 不代表狀態改變，狀態重建要跳過它，但「有沒有被聯絡過」
  # 仍然要算它。
  def historical_states_for(cycle_ids)
    return {} if cycle_ids.empty?

    as_of_cutoff = @livestream.date.end_of_day

    contacted_by_id = CrmCustomerProductFollowUpEvent
      .select("DISTINCT ON (cycle_id) cycle_id, performed_at")
      .where(cycle_id: cycle_ids)
      .where("performed_at <= ?", as_of_cutoff)
      .order(:cycle_id, performed_at: :desc)
      .index_by(&:cycle_id)

    status_by_id = CrmCustomerProductFollowUpEvent
      .select("DISTINCT ON (cycle_id) cycle_id, action, next_contact_date")
      .where(cycle_id: cycle_ids)
      .where.not(action: "note_only")
      .where("performed_at <= ?", as_of_cutoff)
      .order(:cycle_id, performed_at: :desc)
      .index_by(&:cycle_id)

    cycle_ids.index_with do |id|
      status_row = status_by_id[id]
      {
        last_contacted_at: contacted_by_id[id]&.performed_at,
        follow_up_status:  status_row ? CrmCustomerProductFollowUpEvent::RESULTING_STATUS_MAP[status_row.action] : nil,
        next_contact_date: status_row&.next_contact_date
      }
    end
  end

  # paused/repurchased（現在或歷史推估出來的狀態）與「參考日往前 7 天內已聯絡」
  # ——現在跟歷史共用同一份邏輯，因為歷史模式已經把 cycle 的欄位換成推估值了。
  def passes_contact_and_status_exclusions?(cycle)
    return false if %w[paused repurchased].include?(cycle.follow_up_status)
    return false if cycle.last_contacted_at.present? &&
      cycle.last_contacted_at > (reference_date.to_time - RECENTLY_CONTACTED_DAYS.days)

    # 即時模式（未來/今天直播）：系統已偵測到任何同品訂單就排除，不論日期
    # ——這是原本 Phase 3 的行為。歷史模式不能套用同一條規則：active_as_of
    # 已經用「next_same_product_order_date > 直播日期」這個明確的日期比較
    # 篩過一輪了，殘留的 next_same_product_order_date（一定晚於直播日）
    # 正是「直播當時尚未回購」的證明，不能反過來排除它。
    return false if !historical? && cycle.next_same_product_order_date.present?

    true
  end

  def build_hits
    replenish_window = (@livestream.date - REPLENISH_WINDOW_DAYS)..(@livestream.date + REPLENISH_WINDOW_DAYS)

    eligible_cycles.flat_map do |cycle|
      hits = []
      hits << { cycle: cycle, product_key: cycle.product_key, reason: "replenish" } if replenish_window.cover?(cycle.effective_finish_date)

      days_overdue = (@livestream.date - cycle.effective_finish_date).to_i
      reason = win_back_reason_for(days_overdue)
      hits << { cycle: cycle, product_key: cycle.product_key, reason: reason } if reason

      hits.concat(related_product_hits(cycle))
      hits
    end
  end

  def win_back_reason_for(days_overdue)
    return nil unless days_overdue.positive?

    case days_overdue
    when 1..30 then "win_back_1_30"
    when 31..60 then "win_back_31_60"
    when 61..@win_back_max_days then "win_back_61_90"
    else DORMANT_REASON
    end
  end

  # 空 map，恆回傳 []——保留擴充點但不在 MVP 啟用（見檔案頂端註解）。
  def related_product_hits(cycle)
    related_targets = RELATED_PRODUCT_MAP[cycle.product_key] || []
    return [] if related_targets.empty?

    related_targets.map { |target_key| { cycle: cycle, product_key: target_key, reason: "related_product" } }
  end
end
