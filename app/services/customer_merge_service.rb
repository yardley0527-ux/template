# frozen_string_literal: true

# 把「孤兒記錄」（沒有 shopline_id、由訂單匯入時誤建立的重複顧客）
# 合併進「正式顧客記錄」：轉移訂單歸屬、留存合併前快照、刪除孤兒記錄，
# 最後排程重新整理消費分析快取。
class CustomerMergeService
  Result = Struct.new(:success?, :error, :reassigned_orders_count, keyword_init: true)

  def initialize(orphan:, official:, merged_by:)
    @orphan = orphan
    @official = official
    @merged_by = merged_by
  end

  def call
    validate!

    reassigned_count = nil

    ActiveRecord::Base.transaction do
      reassigned_count = ShoplineOrder
        .where(shopline_customer_id: @orphan.id)
        .update_all(shopline_customer_id: @official.id)

      CustomerMergeLog.create!(
        orphan_customer_id:      @orphan.id,
        official_customer_id:    @official.id,
        orphan_snapshot:         @orphan.attributes,
        reassigned_orders_count: reassigned_count,
        merged_by:               @merged_by
      )

      @orphan.destroy!
    end

    RefreshCustomerPurchaseSummariesJob.perform_later

    Result.new(success?: true, reassigned_orders_count: reassigned_count)
  rescue => e
    Result.new(success?: false, error: e.message)
  end

  private

  def validate!
    raise ArgumentError, "不能合併同一筆記錄" if @orphan.id == @official.id
    raise ArgumentError, "來源必須是沒有 Shopline ID 的孤兒記錄" if @orphan.shopline_id.present?
    raise ArgumentError, "目標必須是有 Shopline ID 的正式顧客記錄"  if @official.shopline_id.blank?
  end
end
