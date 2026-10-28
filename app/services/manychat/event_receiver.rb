# frozen_string_literal: true

module Manychat
  # 處理 Flow External Request 送來的事件（POST /manychat/events）。格式見 docs/manychat_data_plan.md。
  # event_id 沒帶時用（帳號、訂閱者、類型、來源、時間到秒）算一個，ManyChat 重試同一筆會得到同一個 id；
  # 連 event_time 都沒帶時用收到時間（以分鐘為單位）算，同一分鐘內同一人同類型的事件會視為同一筆。
  # entry 事件同時記成一次互動（event_type flow_event），讓新客追蹤、來源表現看得到。
  class EventReceiver
    class Invalid < StandardError; end

    def self.call(payload, received_at: Time.current)
      new(payload, received_at).call
    end

    def initialize(payload, received_at)
      @p = payload.is_a?(Hash) ? payload : {}
      @received_at = received_at
    end

    # 回傳 [event, duplicate?]
    def call
      account = ShoplineCustomer.normalize_ig(@p["account"]).to_s
      subscriber_id = (@p["subscriber_id"].presence || @p.dig("subscriber", "id")).to_s.gsub(/[,\s]/, "")
      raise Invalid, "account 或 subscriber_id 缺少／不正確" unless account.match?(ManychatSubscriber::ACCOUNT_KEY_FORMAT) && subscriber_id.match?(/\A\d+\z/)

      type = @p["event_type"].to_s
      raise Invalid, "不支援的 event_type：#{type}" unless ManychatEvent::EVENT_TYPES.key?(type)

      event_time = parse_time(@p["event_time"])
      props = ManychatEvent.clean_properties(type, @p["properties"])
      event_id = @p["event_id"].presence&.to_s&.first(120) || derived_id(account, subscriber_id, type, event_time)

      existing = ManychatEvent.find_by(account_key: account, event_id: event_id)
      return [existing, true] if existing

      ManychatEvent.transaction do
        sub = ManychatSubscriber.find_or_initialize_by(account_key: account, subscriber_id: subscriber_id.to_i)
        ig = @p["ig_username"].presence || @p.dig("subscriber", "ig_username").presence
        sub.ig_username = ig if ig
        sub.last_webhook_at = @received_at
        sub.save!

        event = ManychatEvent.create!(
          account_key: account, subscriber_id: subscriber_id.to_i, manychat_subscriber: sub, event_id: event_id,
          event_type: type, source_key: str(@p["source_key"]), campaign_key: str(@p["campaign_key"]),
          flow_ns: str(@p["flow_ns"]), flow_version: str(@p["flow_version"]),
          properties: props.merge(event_time ? {} : { "event_time_from" => "received_at" }),
          event_time: event_time || @received_at, received_at: @received_at
        )
        record_entry(sub, event) if type == "entry"
        [event, false]
      end
    rescue ActiveRecord::RecordInvalid => e
      raise Invalid, e.record.errors.full_messages.join("；")
    rescue ActiveRecord::RecordNotUnique
      [ManychatEvent.find_by!(account_key: account, event_id: event_id), true]
    end

    private

    def record_entry(sub, event)
      ManychatInteraction.insert_all(
        [{ manychat_subscriber_id: sub.id, interacted_at: event.event_time, source: event.source_key.to_s,
           event_type: "flow_event", created_at: @received_at, updated_at: @received_at }],
        unique_by: :index_manychat_interactions_uniqueness
      )
      sub.update_columns(last_interaction_at: [sub.last_interaction_at, event.event_time].compact.max)
      sub.observe_interaction!(event.event_time, event.source_key)
    end

    def derived_id(account, subscriber_id, type, time)
      stamp = time ? time.to_i : "r#{@received_at.to_i / 60}"
      "d:" + Digest::SHA1.hexdigest([account, subscriber_id, type, @p["source_key"], stamp].join("|"))
    end

    def str(v) = v.to_s.strip.presence&.first(100)

    def parse_time(v)
      v.present? ? Time.zone.parse(v.to_s) : nil
    rescue ArgumentError
      nil
    end
  end
end
