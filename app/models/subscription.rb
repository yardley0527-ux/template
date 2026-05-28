class Subscription < ApplicationRecord
  belongs_to :shopline_customer, foreign_key: :shopline_customer_id

  STATUSES = %w[active paused cancelled completed].freeze
  FREQUENCIES = { 30 => "月訂（30天）", 60 => "雙月訂（60天）", 90 => "季訂（90天）" }.freeze
  DISCOUNT_FOR_FREQUENCY = { 30 => 0.88, 60 => 0.85, 90 => 0.82 }.freeze

  PRODUCT_OPTIONS = [
    "穀胱甘肽1",
    "代謝錠1",
    "全能膠囊1",
    "薑黃膠囊1",
    "NMN1",
    "美白1"
  ].freeze

  SERIES_MAP = {
    "穀胱甘肽" => "穀胱甘肽",
    "代謝"     => "代謝錠",
    "全能"     => "全能",
    "薑黃"     => "薑黃",
    "NMN"      => "NMN",
    "美白"     => "美白"
  }.freeze

  validates :shopline_customer_id, presence: true
  validates :product_name, presence: true
  validates :frequency_days, inclusion: { in: FREQUENCIES.keys }
  validates :discount_rate, numericality: { greater_than: 0, less_than_or_equal_to: 1 }
  validates :unit_price, numericality: { greater_than: 0 }
  validates :quantity, numericality: { greater_than: 0, only_integer: true }
  validates :status, inclusion: { in: STATUSES }
  validates :started_on, presence: true
  validates :next_due_on, presence: true

  scope :active,     -> { where(status: "active") }
  scope :paused,     -> { where(status: "paused") }
  scope :cancelled,  -> { where(status: "cancelled") }
  scope :completed,  -> { where(status: "completed") }
  scope :due_soon,   -> { active.where(next_due_on: ..Date.today + 14) }
  scope :overdue,    -> { active.where(next_due_on: ..Date.today - 1) }

  def discounted_price
    (unit_price * discount_rate).round
  end

  def total_per_delivery
    discounted_price * quantity
  end

  def frequency_label
    FREQUENCIES[frequency_days] || "#{frequency_days}天"
  end

  def discount_label
    "#{(discount_rate * 100).to_i}折"
  end

  def cancellable?
    completed_periods >= min_periods
  end

  def status_label
    { "active" => "訂閱中", "paused" => "暫停", "cancelled" => "已取消", "completed" => "已完成" }[status] || status
  end

  def status_badge_class
    { "active" => "badge-success", "paused" => "badge-warning", "cancelled" => "badge-secondary", "completed" => "badge-info" }[status] || "badge-secondary"
  end

  def advance_period!
    self.completed_periods += 1
    self.next_due_on = next_due_on + frequency_days
    save!
  end
end
