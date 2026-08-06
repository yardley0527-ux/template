# frozen_string_literal: true

# 每一次客服在回購追蹤 Dashboard 對一個 cycle 做的操作，完整歷史紀錄。
# CrmCustomerProductCycle 上的 follow_up_status/last_contacted_at/
# next_contact_date/assigned_to_user_id 只放「目前狀態」給列表快速查詢，
# 這張表才是操作歷史的真正來源——只由 CrmCustomerProductCycleFollowUpService
# 寫入。
class CrmCustomerProductFollowUpEvent < ApplicationRecord
  self.table_name = "crm_customer_product_follow_up_events"

  ACTIONS = %w[
    contacted_waiting_reply
    not_yet_finished
    rescheduled
    not_needed
    no_response
    repurchased
    paused
    note_only
  ].freeze

  ACTION_LABELS = {
    "contacted_waiting_reply" => "已聯絡，等待回覆",
    "not_yet_finished"        => "尚未吃完",
    "rescheduled"             => "指定日期再聯絡",
    "not_needed"              => "暫時不需要",
    "no_response"             => "沒有回覆",
    "repurchased"             => "已回購",
    "paused"                  => "暫停追蹤",
    "note_only"               => "備註"
  }.freeze

  # 每個 action 執行後 cycle.follow_up_status 會變成什麼——只用來做 Phase 3.1
  # 歷史直播名單重建（回放某個過去時間點「當時」的狀態，不能用現在的
  # cycle.follow_up_status 欄位，那只反映最新一次操作後的結果）。
  # note_only 不改變狀態（不在這裡列出，呼叫端要另外跳過 note_only 事件）；
  # not_yet_finished 有兩種分支（給 remaining_days 會清回 nil、只給
  # next_contact_date 會變 rescheduled），歷史重建無法從事件本身分辨是哪一
  # 種，保守估計為 nil（多數情境下的結果），頁面會標示「歷史推估」。
  RESULTING_STATUS_MAP = {
    "contacted_waiting_reply" => "waiting_reply",
    "no_response"             => "waiting_reply",
    "rescheduled"             => "rescheduled",
    "not_needed"              => "paused",
    "paused"                  => "paused",
    "repurchased"             => "repurchased",
    "not_yet_finished"        => nil
  }.freeze

  belongs_to :cycle, class_name: "CrmCustomerProductCycle", foreign_key: :cycle_id, inverse_of: :follow_up_events
  belongs_to :performed_by, class_name: "User", foreign_key: :performed_by_user_id
  belongs_to :livestream, optional: true

  validates :action, presence: true, inclusion: { in: ACTIONS }
  validates :performed_at, presence: true

  scope :recent_first, -> { order(performed_at: :desc) }
end
