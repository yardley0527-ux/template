# frozen_string_literal: true

class CrmProduct < ApplicationRecord
  KEY_FORMAT = /\A[a-z][a-z0-9_]*\z/
  STATUSES   = %w[candidate confirmed merged ignored].freeze

  # 庫存狀態（與映射審核狀態 status 完全獨立）。
  # 沒有 in_stock boolean —— 一律經由下面的語意 method 判定。
  AVAILABILITY_STATUSES = %w[unknown in_stock low_stock out_of_stock preorder discontinued].freeze

  AVAILABILITY_STATUS_LABELS = {
    "unknown"      => "未確認",
    "in_stock"     => "有貨",
    "low_stock"    => "低庫存",
    "out_of_stock" => "缺貨",
    "preorder"     => "預購",
    "discontinued" => "停售"
  }.freeze

  # 只留庫存相關欄位的變更歷史（audit：誰在何時改了庫存狀態）。
  has_paper_trail on: %i[update],
    only: %w[availability_status expected_restock_date actual_restock_date inventory_note]

  has_many :crm_product_aliases, dependent: :destroy
  has_many :active_aliases, -> { where(status: "active") },
           class_name: "CrmProductAlias", inverse_of: :crm_product

  has_many :product_name_mappings, foreign_key: :crm_product_id, inverse_of: :crm_product
  has_many :suggested_for_mappings, class_name: "ProductNameMapping",
           foreign_key: :suggested_crm_product_id, inverse_of: :suggested_crm_product
  belongs_to :reviewed_by, class_name: "User", foreign_key: :reviewed_by_user_id, optional: true
  belongs_to :inventory_status_updated_by, class_name: "User",
             foreign_key: :inventory_status_updated_by_id, optional: true

  validates :key, presence: true, uniqueness: true, format: { with: KEY_FORMAT }
  validates :label, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :availability_status, presence: true, inclusion: { in: AVAILABILITY_STATUSES }

  scope :confirmed,     -> { where(status: "confirmed") }
  scope :for_analysis,  -> { confirmed.where(include_in_analysis: true) }

  # ── 庫存語意（刻意沒有任何 callback：actual_restock_date 填入或
  #    expected_restock_date 過期都「不會」自動改 availability_status，
  #    狀態變更必須由使用者明確操作）──────────────────────────────

  # 回購/用完提醒是否照發。preorder 回傳 true，但呼叫端必須為預購情境
  # 加上「預購中」標注（卡片與訊息模板）。
  def available_for_reminders?
    %w[in_stock low_stock preorder].include?(availability_status)
  end

  # 產品趨勢異常規則（drop/surge/新客變化）是否允許下結論。
  # unknown 與 preorder/out_of_stock/discontinued 一律停用，避免缺貨期誤報。
  def product_trend_detection_enabled?
    %w[in_stock low_stock].include?(availability_status)
  end

  def preorder?
    availability_status == "preorder"
  end

  # discontinued：停止所有回購與補貨提醒（available_for_reminders? 已為 false，
  # 呼叫端另需將既有 open 通知自動 resolve）。
  def discontinued?
    availability_status == "discontinued"
  end

  def availability_unknown?
    availability_status == "unknown"
  end

  # ── Repository helpers (Single Source of Truth for product metadata) ──

  # Labels in id order — drop-in replacement for hard-coded SERIES_OPTIONS arrays.
  def self.series_labels
    for_analysis.order(:id).pluck(:label)
  end

  # Compatibility layer: 舊系統預設產品清單。
  # series_labels_for_filter 在 crm_products 尚未 seed 時自動回傳此清單，
  # 確保所有 controller 的下拉選單和 SQL 在 deploy 後不因空表而 500。
  # crm_products seeded 後此常數不再被使用（Registry 路徑接管）。
  LEGACY_SERIES_OPTIONS = %w[
    代謝錠 全能 薑黃 膠原蛋白 美白 蝦紅素 清纖粉 魚油 私密粉 益生菌 穀胱甘肽 維DK鈣
  ].freeze

  # Bridge for controllers that filter against customer_series_loyalties.series or
  # customer_purchase_summaries.first_series. The label divergence this maps was
  # fixed by AlignCrmProductDisplayLabels (labels now match the series values),
  # making this a no-op — kept only to cover the window where this code is
  # deployed but that migration hasn't run yet. Safe to delete next cleanup.
  SERIES_FILTER_OVERRIDES = {
    "B群／全能" => "全能",
    "膠原飲"   => "膠原蛋白"
  }.freeze

  def self.series_labels_for_filter
    labels = series_labels
    return LEGACY_SERIES_OPTIONS if labels.empty?
    labels.map { |l| SERIES_FILTER_OVERRIDES.fetch(l, l) }
  end

  # Keys in id order.
  def self.all_keys
    for_analysis.order(:id).pluck(:key)
  end

  # Find by key or raise (avoids scattered find_by + nil checks).
  def self.fetch(key)
    find_by!(key: key.to_s)
  end

  # Build the legacy-compatible LIKE sql_pattern for a product_key.
  # Returns the stored sql_pattern if present; falls back to a label-based LIKE.
  def self.sql_for(key)
    crm = find_by(key: key.to_s)
    crm&.sql_pattern.presence || crm && "product_name LIKE '%#{crm.label}%'"
  end

  # Build a Regexp from the stored regex_pattern, or nil.
  def compiled_regex
    return nil unless regex_pattern.present?
    Regexp.new(regex_pattern)
  rescue RegexpError
    nil
  end

  # ── Alias-aware matching（Phase 5 修正）───────────────────────────
  #
  # sql_pattern 只在建立當下手動維護，不會因為 CrmProductAlias 新增就自動
  # 更新（ProductAliasRegexGeneratorService 只重生 regex_pattern，不動
  # sql_pattern）——已知 typo（例如「榖胱甘肽」「益生箘」）就算已經在
  # active_aliases 裡登記，用 sql_pattern 做訂單比對還是抓不到，導致這些
  # 顧客完全不會被建立 cycle。這裡刻意不去改 sql_pattern 本身或共用的
  # regex 產生流程（影響面太廣、不是這次修正範圍），只在比對當下把
  # active_aliases 併進來，讓「這筆品名算不算這個產品」的判斷跟 alias
  # registry 同步，不建立第二套獨立的解析規則。

  # LIKE 子字串（sql_pattern 解析出來的 + active_aliases 的別名字串）。
  def matching_substrings
    from_pattern = sql_pattern.to_s.scan(/LIKE\s+'%([^%]+)%'/i).flatten
    from_aliases = active_aliases.map(&:alias_name)
    (from_pattern + from_aliases).uniq
  end

  # 給 SQL 層級 WHERE 用：原本的 sql_pattern OR 每個 alias 各自的 LIKE 條件。
  def matching_sql_pattern
    alias_names = active_aliases.map(&:alias_name)
    return sql_pattern if alias_names.empty?

    conn = self.class.connection
    clauses = [sql_pattern] + alias_names.map { |a| "product_name LIKE #{conn.quote("%#{a}%")}" }
    clauses.compact.join(" OR ")
  end

  # 批次版：{ key => [substrings...] }，避免對多個產品逐一查詢造成 N+1。
  def self.substring_matchers(keys: nil)
    scope = confirmed
    scope = scope.where(key: keys) if keys
    scope.includes(:active_aliases).each_with_object({}) do |product, acc|
      acc[product.key] = product.matching_substrings
    end
  end
end
