# ManyChat 單次互動，見 CreateManychatInteractions / AddEventTrackingToManychat migration 說明。
class ManychatInteraction < ApplicationRecord
  EVENT_TYPES = {
    "sheet_row"            => { label: "試算表記錄", source_reliable: true },
    "flow_event"           => { label: "Flow 回傳", source_reliable: true },
    "api_last_interaction" => { label: "API 補入（最後互動）", source_reliable: false }
  }.freeze

  belongs_to :manychat_subscriber

  validates :event_type, inclusion: { in: EVENT_TYPES.keys }

  def event_type_label = EVENT_TYPES.dig(event_type, :label)

  # API 補入的來源是補入當下「來源」欄的值，不一定是那次互動真正的來源
  def source_reliable? = EVENT_TYPES.dig(event_type, :source_reliable)
end
