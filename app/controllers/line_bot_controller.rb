# frozen_string_literal: true

# LINE webhook（公開端點，不走登入）：機器人被邀進／踢出群組時記下 group_id，
# 每日報告才知道要推到哪裡；有人加小幫手好友或私訊它時，也記下 user_id（名字前面加「個人：」），
# 可以到 /line_bot_groups 勾選報告、或用 rake line_bot:preview 收測試報告。
# 其他事件（群組聊天訊息）一律忽略，也不回覆。用 Channel secret 驗簽章，假的請求一律 400。
class LineBotController < ActionController::Base
  skip_forgery_protection

  def webhook
    body = request.raw_post
    return head :bad_request unless LineBot::Client.valid_signature?(body, request.headers["X-Line-Signature"])

    JSON.parse(body).fetch("events", []).each { |event| handle(event) }
    head :ok
  end

  private

  def handle(event)
    return handle_user(event) if event.dig("source", "type") == "user"

    group_id = event.dig("source", "groupId")
    return if group_id.blank?

    case event["type"]
    when "join"
      group = LineBotGroup.find_or_initialize_by(group_id: group_id)
      group.update!(active: true, joined_at: Time.current, left_at: nil,
                    name: LineBot::Client.new.group_name(group_id) || group.name)
    when "leave"
      LineBotGroup.where(group_id: group_id).update_all(active: false, left_at: Time.current)
    end
  end

  # 個人聊天室：加好友或私訊時記下（已記過就不再查名字）；封鎖時標成 inactive
  def handle_user(event)
    user_id = event.dig("source", "userId")
    return if user_id.blank?

    case event["type"]
    when "follow", "message"
      chat = LineBotGroup.find_or_initialize_by(group_id: user_id)
      return if chat.persisted? && chat.active

      name = LineBot::Client.new.user_name(user_id)
      chat.update!(active: true, joined_at: Time.current, left_at: nil,
                   name: name ? "個人：#{name}" : (chat.name || "個人：#{user_id.last(6)}"))
    when "unfollow"
      LineBotGroup.where(group_id: user_id).update_all(active: false, left_at: Time.current)
    end
  end
end
