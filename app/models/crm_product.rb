# frozen_string_literal: true

class CrmProduct < ApplicationRecord
  KEY_FORMAT = /\A[a-z][a-z0-9_]*\z/
  STATUSES   = %w[candidate confirmed merged ignored].freeze

  has_many :crm_product_aliases, dependent: :destroy
  has_many :active_aliases, -> { where(status: "active") },
           class_name: "CrmProductAlias", inverse_of: :crm_product

  has_many :product_name_mappings, foreign_key: :crm_product_id, inverse_of: :crm_product
  has_many :suggested_for_mappings, class_name: "ProductNameMapping",
           foreign_key: :suggested_crm_product_id, inverse_of: :suggested_crm_product
  belongs_to :reviewed_by, class_name: "User", foreign_key: :reviewed_by_user_id, optional: true

  validates :key, presence: true, uniqueness: true, format: { with: KEY_FORMAT }
  validates :label, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :confirmed,     -> { where(status: "confirmed") }
  scope :for_analysis,  -> { confirmed.where(include_in_analysis: true) }

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
  # customer_purchase_summaries.first_series (written by refresh services using legacy
  # labels). Maps two diverged CrmProduct labels back to the values the DB stores.
  # TODO: remove after aligning CrmProduct labels + migrating DB series columns.
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
end
