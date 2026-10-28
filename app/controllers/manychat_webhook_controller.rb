# frozen_string_literal: true

# ManyChat webhook（公開端點，不走登入）：Flow 裡的 External Request 動作打過來，
# 記下訂閱者 subscriber_id ↔ IG 帳號，並對到我們的客人。
#
# ManyChat 設定：POST <網域>/manychat/webhook，Header 帶 X-Manychat-Token
# （= ENV MANYCHAT_WEBHOOK_TOKEN），Body 用 JSON：
#   { "account": "shengting.slim", "subscriber": <Full Subscriber Data> }
# account 是這個 Flow 所在的 IG 帳號名稱（如 shengting.slim），大小寫與 @ 不拘。
# 回傳的 matched / membership_level 可在 Response mapping 存成自訂欄位，讓 Flow 分流。
# matched 只看人工確認過的關聯（verified），候選比對不回傳任何會員資訊。
#
# POST <網域>/manychat/events：Flow 重要節點的事件（同一個 token），格式見 docs/manychat_data_plan.md。
class ManychatWebhookController < ActionController::Base
  skip_forgery_protection

  def create
    return head :unauthorized unless valid_token?

    payload = JSON.parse(request.raw_post)
    sub = payload["subscriber"].is_a?(Hash) ? payload["subscriber"] : payload
    subscriber_id = sub["id"].presence || sub["subscriber_id"].presence
    account_key = ShoplineCustomer.normalize_ig(payload["account"]).to_s
    unless subscriber_id && account_key.match?(ManychatSubscriber::ACCOUNT_KEY_FORMAT)
      return render json: { error: "account 或 subscriber id 缺少／不正確" }, status: :unprocessable_entity
    end

    record = ManychatSubscriber.find_or_initialize_by(account_key: account_key, subscriber_id: subscriber_id)
    record.update!(
      ig_username: sub["ig_username"].presence || record.ig_username,
      ig_id: sub["ig_id"].presence || record.ig_id,
      name: sub["name"].presence || record.name,
      last_interaction_at: parse_time(sub["last_interaction"]) || record.last_interaction_at,
      raw_payload: payload,
      last_webhook_at: Time.current
    )

    render json: {
      matched: record.shopline_customer_id.present?,
      membership_level: record.shopline_customer&.membership_level
    }
  rescue JSON::ParserError
    head :bad_request
  end

  def event
    return head :unauthorized unless valid_token?

    event, duplicate = Manychat::EventReceiver.call(JSON.parse(request.raw_post))
    render json: { ok: true, duplicate: duplicate, event_id: event.event_id }
  rescue Manychat::EventReceiver::Invalid => e
    render json: { ok: false, error: e.message }, status: :unprocessable_entity
  rescue JSON::ParserError
    head :bad_request
  end

  private

  def valid_token?
    expected = ENV["MANYCHAT_WEBHOOK_TOKEN"].to_s
    expected.present? &&
      ActiveSupport::SecurityUtils.secure_compare(expected, request.headers["X-Manychat-Token"].to_s)
  end

  def parse_time(value)
    Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end
end
