# path: app/services/message_list_builder.rb
# frozen_string_literal: true

# 建立一批訊息名單：給定 email 清單，正規化去重後從 shopline_customers
# （姓名／卡別／id）與 shopline_orders（最新 IG）補齊快照欄位。
#
#   MessageListBuilder.create!(
#     name: "代謝錠回購×清纖粉 7月推播",
#     sent_on: Date.new(2026, 7, 10),
#     target_product: "清纖粉",
#     source_note: "代謝錠回購 cohort × 買過清纖粉",
#     emails: [...],
#     segments: { "a@x.com" => "回購鐵粉" }   # 選填：email → 分類標籤
#   )
class MessageListBuilder
  def self.create!(name:, sent_on:, target_product:, emails:, source_note: nil, segments: {})
    normalized = emails.filter_map { |e| e.to_s.strip.downcase.presence }.uniq
    raise ArgumentError, "emails 不可為空" if normalized.empty?

    customers = customer_snapshots(normalized)
    igs       = latest_ig_by_email(normalized)

    MessageList.transaction do
      list = MessageList.create!(
        name: name, sent_on: sent_on, target_product: target_product, source_note: source_note
      )
      now = Time.current
      rows = normalized.map do |email|
        c = customers[email] || {}
        {
          message_list_id: list.id,
          email: email,
          full_name: c["full_name"],
          instagram_account: igs[email],
          membership_level: c["membership_level"],
          segment: segments[email],
          shopline_customer_id: c["id"],
          created_at: now,
          updated_at: now
        }
      end
      MessageListRecipient.insert_all!(rows)
      list
    end
  end

  def self.customer_snapshots(emails)
    ShoplineCustomer
      .where("LOWER(TRIM(email)) IN (?)", emails)
      .pluck(Arel.sql("LOWER(TRIM(email))"), :id, :full_name, :membership_level)
      .to_h { |email, id, name, level| [email, { "id" => id, "full_name" => name, "membership_level" => level }] }
  end
  private_class_method :customer_snapshots

  def self.latest_ig_by_email(emails)
    sql = <<~SQL
      SELECT DISTINCT ON (LOWER(TRIM(email))) LOWER(TRIM(email)) AS email_key, instagram_account
      FROM shopline_orders
      WHERE LOWER(TRIM(email)) IN (#{emails.map { |e| ActiveRecord::Base.connection.quote(e) }.join(', ')})
        AND instagram_account IS NOT NULL AND instagram_account <> ''
      ORDER BY LOWER(TRIM(email)), order_date DESC
    SQL
    ActiveRecord::Base.connection.select_all(sql).to_a.to_h { |r| [r["email_key"], r["instagram_account"]] }
  end
  private_class_method :latest_ig_by_email
end
