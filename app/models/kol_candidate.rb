class KolCandidate < ApplicationRecord
  STATUSES = %w[待接洽 已接洽 未回覆 已回覆 合作中 已合作 婉拒].freeze
  SENTIMENT_LABELS = {
    "positive" => "正面",
    "neutral"  => "中性",
    "negative" => "負面",
    "mixed"    => "毀譽參半",
    "unknown"  => "尚無資料",
  }.freeze

  has_many :kol_quote_items, -> { order(:created_at) }, dependent: :destroy
  has_many :kol_metric_snapshots, -> { order(fetched_at: :desc) }, dependent: :destroy
  has_many :kol_buzz_checks, -> { order(checked_at: :desc) }, dependent: :destroy

  accepts_nested_attributes_for :kol_quote_items, allow_destroy: true, reject_if: :all_blank

  validates :name, presence: true
  validates :status, inclusion: { in: STATUSES }

  before_validation { self.status = STATUSES.first if status.blank? }

  def latest_metric(platform)
    kol_metric_snapshots.where(platform: platform).order(fetched_at: :desc).first
  end

  def latest_metrics_by_platform
    kol_metric_snapshots.group_by(&:platform).transform_values { |snaps| snaps.max_by(&:fetched_at) }
  end

  def latest_buzz_check
    kol_buzz_checks.order(checked_at: :desc).first
  end

  def total_one_time_quote
    kol_quote_items.where(period: [nil, ""]).sum(:amount)
  end

  def total_recurring_quote
    kol_quote_items.where.not(period: [nil, ""]).sum(:amount)
  end

  def cost_per_thousand_followers(platform: "instagram")
    snapshot = latest_metric(platform)
    return nil if snapshot&.followers_count.to_i.zero? || total_one_time_quote.zero?

    (total_one_time_quote / snapshot.followers_count * 1000).round
  end
end
