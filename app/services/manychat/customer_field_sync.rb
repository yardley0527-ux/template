# frozen_string_literal: true

module Manychat
  # 把對到客人的訂閱者，寫 CRM 摘要到 ManyChat 自訂欄位，客服在 Inbox 右側就看得到。
  # 只處理有設 API 金鑰的帳號；內容沒變（fields_digest 相同）就跳過。
  class CustomerFieldSync
    FIELDS = {
      "卡別"       => "text",
      "累積消費"   => "number",
      "訂單數"     => "number",
      "最近購買"   => "text",
      "最近購買日" => "date"
    }.freeze
    MAX_PRODUCTS_LENGTH = 200

    def self.call
      new.call
    end

    def initialize(client_factory: ->(account) { Client.for_account(account) })
      @client_factory = client_factory
    end

    def call
      result = { synced: 0, skipped: 0, errors: [] }
      scope = ManychatSubscriber.where.not(shopline_customer_id: nil).includes(:shopline_customer)

      scope.group_by(&:account_key).each do |account, subscribers|
        client = @client_factory.call(account)
        next result[:skipped] += subscribers.size if client.nil?

        begin
          ensure_fields!(client)
        rescue Client::Error => e
          result[:errors] << "#{account}: 建立欄位失敗 #{e.message}"
          next
        end

        subscribers.each do |sub|
          fields = self.class.fields_for(sub.shopline_customer)
          digest = Digest::MD5.hexdigest(fields.to_json)
          next result[:skipped] += 1 if sub.fields_digest == digest

          client.set_custom_fields(sub.subscriber_id, fields.compact)
          sub.update_columns(fields_digest: digest, fields_synced_at: Time.current)
          result[:synced] += 1
          sleep 0.12 # 官方上限 10 次/秒
        rescue Client::Error => e
          result[:errors] << "#{account}/#{sub.subscriber_id}: #{e.message}"
        end
      end
      result
    end

    def self.fields_for(customer)
      last_order = ShoplineOrder.where(shopline_customer_id: customer.id).where.not(order_date: nil)
                                .order(order_date: :desc).pick(:order_number, :order_date)
      products = if last_order
                   ShoplineOrder.where(shopline_customer_id: customer.id, order_number: last_order[0])
                                .where.not(product_name: [nil, ""])
                                .group(:product_name).maximum(:quantity) # 同品項會有成對重複列，取最大不加總
                                .map { |name, qty| qty.to_i > 1 ? "#{name}×#{qty}" : name }
                                .join("、")[0, MAX_PRODUCTS_LENGTH]
                 end

      {
        "卡別"       => customer.membership_level.presence,
        "累積消費"   => customer.total_amount&.to_i,
        "訂單數"     => customer.order_count,
        "最近購買"   => products.presence,
        "最近購買日" => last_order && last_order[1].in_time_zone("Asia/Taipei").to_date.iso8601
      }
    end

    private

    def ensure_fields!(client)
      existing = client.custom_fields.map { |f| f["name"] }
      (FIELDS.keys - existing).each do |name|
        client.create_custom_field(caption: name, type: FIELDS[name], description: "CRM 同步（smartadmin）")
      end
    end
  end
end
