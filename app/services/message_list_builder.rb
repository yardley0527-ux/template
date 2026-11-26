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
#
# 黑名單客人（customer_profiles.brand_ambassador_blacklisted 或 blacklisted）一律
# 排除，不管是手動灌的還是每日自動快照。同一人常用好幾個 email 下單，所以也用
# IG 帳號把黑名單展開到同一人的其他 email。被排除的人數／姓名會補記在
# source_note，日後查得到；排除後一個人都不剩就不建名單，回傳 nil。
# CRM 標記「已流失」的客人也排除：有指定流失產品的，只在名單 target_product 對到時排除；
# 沒指定產品＝整個客人流失，所有名單都排除。
class MessageListBuilder
  def self.create!(name:, sent_on:, target_product:, emails:, source_note: nil, segments: {}, source: "manual", with_line_id: false)
    normalized = emails.filter_map { |e| e.to_s.strip.downcase.presence }.uniq
    raise ArgumentError, "emails 不可為空" if normalized.empty?

    blacklisted = blacklisted_emails
    excluded = normalized & blacklisted.keys
    normalized -= excluded
    return nil if normalized.empty?

    if excluded.any?
      names = excluded.map { |e| blacklisted[e].presence || e }.uniq
      source_note = [source_note.presence, "已排除黑名單 #{excluded.size} 人（#{names.join('、')}）"].compact.join("\n")
    end

    churned = churned_emails(target_product)
    churned_hit = normalized & churned.keys
    normalized -= churned_hit
    return nil if normalized.empty?

    if churned_hit.any?
      names = churned_hit.map { |e| churned[e] }.uniq
      source_note = [source_note.presence, "已排除已流失客人 #{churned_hit.size} 人（#{names.join('、')}）"].compact.join("\n")
    end

    customers = customer_snapshots(normalized)
    igs       = latest_ig_by_email(normalized)

    MessageList.transaction do
      list = MessageList.create!(
        name: name, sent_on: sent_on, target_product: target_product, source_note: source_note, source: source
      )
      now = Time.current
      rows = normalized.map do |email|
        c = customers[email] || {}
        {
          message_list_id: list.id,
          email: email,
          full_name: c["full_name"],
          instagram_account: igs[email],
          line_id: (c["line_id"].presence if with_line_id),
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

  # email → 姓名。黑名單本人的 email，加上跟黑名單同 IG 的其他帳號。
  # CrmBirthdays::LineDigest 也用這個排除黑名單。
  def self.blacklisted_emails
    flagged = ShoplineCustomer.joins(:customer_profile)
                              .where("customer_profiles.brand_ambassador_blacklisted OR customer_profiles.blacklisted")
                              .pluck(:email, :instagram_account, :full_name)
    igs = flagged.filter_map { |_, ig, _| normalize_ig(ig) }.uniq

    rows = flagged.map { |email, _, name| [email, name] }
    if igs.any?
      rows += ShoplineCustomer.where("LOWER(TRIM(instagram_account)) IN (?)", igs).pluck(:email, :full_name)
    end
    rows.each_with_object({}) do |(email, name), h|
      key = email.to_s.strip.downcase
      h[key] ||= name if key.present?
    end
  end

  # email → 「姓名（流失產品）」。CRM 標記已流失、且流失產品對得上這份名單 target_product 的客人
  # （沒指定產品＝整個客人流失，任何名單都排除），一樣用 IG 展開到同一人的其他帳號。
  def self.churned_emails(target_product)
    flagged = ShoplineCustomer.joins(:customer_profile)
                              .where(customer_profiles: { churned: true })
                              .includes(:customer_profile)
                              .select { |c| c.customer_profile.churned_for?(target_product) }
    return {} if flagged.empty?

    label = ->(c) { products = c.customer_profile.churned_products
                    products.present? ? "#{c.full_name}：#{products.join('/')}" : "#{c.full_name}：全部" }
    rows = flagged.map { |c| [c.email, label.call(c)] }
    by_ig = flagged.each_with_object({}) { |c, h| ig = normalize_ig(c.instagram_account); h[ig] ||= label.call(c) if ig && ig.length >= 3 }
    if by_ig.any?
      ShoplineCustomer.where("LOWER(TRIM(instagram_account)) IN (?)", by_ig.keys).pluck(:email, :instagram_account).each do |email, ig|
        rows << [email, by_ig[normalize_ig(ig)]]
      end
    end
    rows.each_with_object({}) do |(email, name), h|
      key = email.to_s.strip.downcase
      h[key] ||= name if key.present?
    end
  end

  # 黑名單客人的 IG（小寫、去掉 @）。用來比對 email 對不到、但 IG 是同一人的訂單。
  def self.blacklisted_igs
    ShoplineCustomer.joins(:customer_profile)
                    .where("customer_profiles.brand_ambassador_blacklisted OR customer_profiles.blacklisted")
                    .pluck(:instagram_account)
                    .filter_map { |ig| normalize_ig(ig) }
                    .reject { |ig| ig.length < 3 || %w[nil null n/a].include?(ig) }
                    .to_set
  end

  def self.normalize_ig(ig)
    v = ig.to_s.strip.downcase.delete_prefix("@")
    v.presence unless %w[無 - none].include?(v)
  end

  def self.customer_snapshots(emails)
    ShoplineCustomer
      .where("LOWER(TRIM(email)) IN (?)", emails)
      .pluck(Arel.sql("LOWER(TRIM(email))"), :id, :full_name, :membership_level, :line_id)
      .to_h { |email, id, name, level, line_id| [email, { "id" => id, "full_name" => name, "membership_level" => level, "line_id" => line_id }] }
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
