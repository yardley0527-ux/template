# frozen_string_literal: true

# 顧客 × 產品 × 購買週期歷史。每一次符合追蹤產品的有效購買都會產生一列，
# 與 CrmCustomerProductTracking（只保留最新一筆快照的 rollup cache）並存──
# 這張表刻意保留每個週期各自的狀態，才能做人工覆寫、下一筆訂單配對、
# 同品回購/跨品購買/同品加購/尚未回購 分類，且互不影響。
#
# 只由 CrmCustomerProductCycleBuilderService（rollup upsert）與
# CrmCustomerProductCycleOverrideService（人工覆寫）寫入。
class CrmCustomerProductCycle < ApplicationRecord
  MATCH_STATUSES = %w[
    same_product_repurchase
    cross_product_purchase
    same_product_addon
    not_yet_repurchased
  ].freeze

  validates :identity_key, presence: true
  validates :email, presence: true
  validates :product_key, presence: true
  validates :cycle_started_at, presence: true
  validates :bottle_count, presence: true,
            numericality: { only_integer: true, greater_than: 0 }
  validates :estimated_usage_days, presence: true,
            numericality: { only_integer: true, greater_than: 0 }
  validates :estimated_finish_date, presence: true
  validates :suggested_contact_date, presence: true
  validates :match_status, presence: true, inclusion: { in: MATCH_STATUSES }
  validates :refreshed_at, presence: true
  validates :cycle_started_at,
            uniqueness: { scope: %i[identity_key product_key] }

  scope :for_product, ->(product_key) { where(product_key: product_key) }
  scope :open_cycles, -> { where(match_status: "not_yet_repurchased") }
  scope :matched, -> { where.not(match_status: "not_yet_repurchased") }
  scope :manually_overridden, -> {
    where.not(manual_override_remaining_days: nil).or(where.not(manual_override_finish_date: nil))
  }

  def manual_override?
    manual_override_remaining_days.present? || manual_override_finish_date.present?
  end

  # 人工覆寫優先序：manual_override_remaining_days > manual_override_finish_date
  # > 系統估算 estimated_finish_date。兩個覆寫欄位都有值時，天數覆寫優先，
  # 因為使用者通常是看著「還剩幾天」在調整,日期覆寫是次要輸入管道。
  #
  # 覆寫剩餘天數會以「覆寫當下」為基準換算成一個固定的用完日
  # （manual_override_at + remaining_days），之後隨著今天日期前進持續遞減──
  # 不是把 remaining_days 原樣凍結，否則過幾天畫面上的剩餘天數就會跟現實脫節。
  def effective_finish_date
    if manual_override_remaining_days.present?
      base_date = manual_override_at&.to_date || Date.current
      return base_date + manual_override_remaining_days
    end
    return manual_override_finish_date if manual_override_finish_date.present?

    estimated_finish_date
  end

  def effective_remaining_days
    (effective_finish_date - Date.current).to_i
  end

  def effective_overdue_days
    days = effective_remaining_days
    days.negative? ? -days : 0
  end
end
