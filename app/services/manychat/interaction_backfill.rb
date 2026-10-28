# frozen_string_literal: true

module Manychat
  # 試算表的 Flow 不一定有填 time（新追蹤、部分貼文 Flow），那些列 SheetImporter 記不成互動。
  # 這裡用 API（subscriber/getInfo）查訂閱者的狀態、訂閱時間、「來源」欄與最後互動時間，
  # 最後互動附近（MATCH_WINDOW 內）沒有互動紀錄就補一筆，來源用「來源」欄目前的值。
  # API 只給最後一次互動，兩次同步之間互動多次只會補到最後一次。
  #
  # 補入的互動標 event_type api_last_interaction：來源只是補入當下的欄位值，分析時不當成確定來源。
  # 順便存 tags（ManyChat 標籤名稱）與同步時間。
  #
  # 要查的人：沒查過的（api_checked_at 空白，SheetImporter 看到新的列也會清空）、
  # 最近 VISITOR_DAYS 天加入的 visitor（之後可能才開始私訊）每 VISITOR_RECHECK 查一次。
  # 排程每小時跑一次，間隔設 50 分鐘才不會因為差幾秒變成兩小時查一次。
  class InteractionBackfill
    SOURCE_FIELD = "來源"
    MATCH_WINDOW = 10.minutes
    VISITOR_DAYS = 7
    VISITOR_RECHECK = 50.minutes

    def self.call
      new.call
    end

    def initialize(client_factory: ->(account) { Client.for_account(account) }, now: Time.current)
      @client_factory = client_factory
      @now = now
    end

    def call
      result = { checked: 0, interactions: 0, skipped: 0, errors: [] }

      due_subscribers.group_by(&:account_key).each do |account, subscribers|
        client = @client_factory.call(account)
        next result[:skipped] += subscribers.size if client.nil?

        subscribers.each do |sub|
          info = client.subscriber_info(sub.subscriber_id)
          result[:interactions] += 1 if apply(sub, info)
          result[:checked] += 1
          sleep 0.12 # 官方上限 10 次/秒
        rescue Client::Error => e
          result[:errors] << "#{account}/#{sub.subscriber_id}: #{e.message}"
        end
      end
      result
    end

    private

    def due_subscribers
      ManychatSubscriber.where(api_checked_at: nil)
                        .or(ManychatSubscriber.where(status: "visitor")
                                              .where("subscribed_at > ?", @now - VISITOR_DAYS.days)
                                              .where("api_checked_at < ?", @now - VISITOR_RECHECK))
                        .order(:id).to_a
    end

    # 有補互動回傳 true
    def apply(sub, info)
      source = Array(info["custom_fields"]).find { |f| f["name"] == SOURCE_FIELD }&.dig("value").to_s.strip
      last_at = [info["ig_last_interaction"], info["last_interaction"]].filter_map { |v| parse_time(v) }.max

      sub.update_columns(status: info["status"].presence, subscribed_at: parse_time(info["subscribed"]),
                         source: source.presence, api_checked_at: @now,
                         tags: Array(info["tags"]).filter_map { |t| t["name"].presence }, tags_synced_at: @now,
                         last_interaction_at: [sub.last_interaction_at, last_at].compact.max)
      return false if last_at.nil?
      return false if sub.manychat_interactions.where(interacted_at: (last_at - MATCH_WINDOW)..(last_at + MATCH_WINDOW)).exists?

      sub.manychat_interactions.create!(interacted_at: last_at, source: source, event_type: "api_last_interaction")
      sub.observe_interaction!(last_at, source)
      true
    end

    def parse_time(value)
      value.present? ? Time.zone.parse(value.to_s) : nil
    rescue ArgumentError
      nil
    end
  end
end
