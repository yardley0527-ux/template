class ManychatCheck < ApplicationRecord
  ACCOUNTS = {
    "shengting.bodyfit"   => "清纖粉",
    "shengting.collagen"  => "膠原蛋白",
    "shengting.fishoil"   => "魚油",
    "shengting.light"     => "冰晶番茄",
    "shengting.metabolic" => "代謝錠",
    "shengting.probiotic" => "益生菌",
    "shengting.slim"      => "薑黃",
  }.freeze

  TIME_SLOTS = { "morning" => "上班", "evening" => "下班" }.freeze

  belongs_to :checked_by, class_name: "User", optional: true, foreign_key: :checked_by_user_id

  validates :date, presence: true
  validates :account_key, inclusion: { in: ACCOUNTS.keys }
  validates :time_slot, inclusion: { in: TIME_SLOTS.keys }
  validates :account_key, uniqueness: { scope: [:date, :time_slot] }

  def self.rows_for(date)
    ACCOUNTS.keys.each do |account_key|
      TIME_SLOTS.keys.each do |time_slot|
        find_or_create_by!(date: date, account_key: account_key, time_slot: time_slot)
      end
    end
    where(date: date)
  end
end
