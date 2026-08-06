# frozen_string_literal: true

# 回購追蹤 Dashboard 唯一的查詢定義來源——KPI 卡片跟列表共用同一套
# active_follow_up + 篩選邏輯，數字保證對得起來（規格明確要求）。
#
# 分頁用既有慣例（手動 offset/limit，本專案沒有用 Kaminari/will_paginate）。
class CrmRepurchaseDashboardQuery
  PER_PAGE = 20

  # 「暫停追蹤」「已回購」預設不出現在待辦列表，但狀態篩選可以明確找到——
  # follow_up_status 多數情況是 NULL（還沒有人工狀態），where.not(hash) 在
  # Rails 會產生純 SQL NOT IN，NULL 欄位會被 NOT IN 排除掉（SQL 三值邏輯），
  # 等於預設列表會整批消失。這裡改成明確的 NULL-safe 寫法。
  DEFAULT_HIDDEN_STATUSES = %w[paused repurchased].freeze

  def initialize(params = {}, reference_date: Date.current)
    @product_key    = params[:product_key].presence
    @status         = params[:status].presence
    @assigned_to    = params[:assigned_to].presence
    @q              = params[:q].to_s.strip.presence
    @page           = [params[:page].to_i, 1].max
    @reference_date = reference_date
  end

  def cycles
    @cycles ||= base_filtered_scope
      .order(Arel.sql("(#{CrmCustomerProductCycle.sort_priority_sql(reference_date: @reference_date)}) ASC, crm_customer_product_cycles.id ASC"))
      .includes(:assigned_to)
      .offset((page - 1) * PER_PAGE)
      .limit(PER_PAGE)
  end

  def total_count
    @total_count ||= base_filtered_scope.count
  end

  def total_pages
    [(total_count.to_f / PER_PAGE).ceil, 1].max
  end

  def page
    [@page, total_pages].min
  end

  # 5 個 KPI：前 4 個直接重用 with_status_filter（跟列表篩選同一份定義），
  # 「本月同品回購」語意不同（成果指標，不是待辦狀態），另外定義，見底下註解。
  def kpis
    base = active_scope
    {
      overdue:                CrmCustomerProductCycle.with_status_filter(base, "overdue",       reference_date: @reference_date).count,
      due_today:               CrmCustomerProductCycle.with_status_filter(base, "due_today",     reference_date: @reference_date).count,
      due_soon:                CrmCustomerProductCycle.with_status_filter(base, "due_soon",      reference_date: @reference_date).count,
      waiting_reply:            CrmCustomerProductCycle.with_status_filter(base, "waiting_reply", reference_date: @reference_date).count,
      repurchased_this_month:  repurchased_this_month_count
    }
  end

  private

  # active_follow_up 本身是一個 DISTINCT ON + Sort 的較重查詢（39K 列時約
  # 20-50ms）。kpis 要算 4 次、列表的 total_count/cycles 各要用一次，如果每次
  # 都重新展開整個 DISTINCT ON 子查詢，一個頁面請求會把它重複執行 6 次。
  # 這裡只 pluck 一次 id 集合，之後全部改成 WHERE id IN (id 集合)——用一次
  # 較貴的查詢換掉六次，而不是零查詢換六次貴查詢。
  def active_ids
    @active_ids ||= CrmCustomerProductCycle.active_follow_up.pluck(:id)
  end

  def active_scope
    @active_scope ||= CrmCustomerProductCycle.where(id: active_ids)
  end

  # 「本月同品回購」是成果指標（這個月有多少人真的回購了），不是「待辦」的
  # 一種，所以不透過 active_follow_up（那個 scope 會刻意排除已回購的
  # cycle）。直接看 matcher 偵測到的 next_same_product_order_date 落在本月
  # 的 cycle 數——不論這個 cycle 現在還算不算「active」。
  def repurchased_this_month_count
    range = @reference_date.beginning_of_month..@reference_date.end_of_month
    CrmCustomerProductCycle.where(next_same_product_order_date: range).count
  end

  def base_filtered_scope
    @base_filtered_scope ||= begin
      scope = active_scope

      scope = if @status.present?
        CrmCustomerProductCycle.with_status_filter(scope, @status, reference_date: @reference_date)
      else
        scope.where(
          "crm_customer_product_cycles.follow_up_status IS NULL OR crm_customer_product_cycles.follow_up_status NOT IN (?)",
          DEFAULT_HIDDEN_STATUSES
        )
      end

      scope = scope.where(product_key: @product_key)         if @product_key
      scope = scope.where(assigned_to_user_id: @assigned_to) if @assigned_to
      scope = apply_search(scope)                             if @q
      scope
    end
  end

  def apply_search(scope)
    like = "%#{@q}%"
    matching_emails = ShoplineCustomer
      .where("full_name ILIKE :q OR mobile_phone ILIKE :q OR email ILIKE :q", q: like)
      .limit(500).pluck(:email)

    scope.where(
      "crm_customer_product_cycles.email ILIKE :q OR crm_customer_product_cycles.email IN (:emails)",
      q: like, emails: matching_emails.presence || [""]
    )
  end
end
