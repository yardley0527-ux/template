# frozen_string_literal: true

# LINE webhook（公開端點，不走登入）：只做一件事——機器人被邀進／踢出群組時
# 記下 group_id，每日報告才知道要推到哪裡。其他事件（群組聊天訊息）一律忽略，
# 也不回覆。用 Channel secret 驗簽章，假的請求一律 400。
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
end
