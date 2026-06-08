# frozen_string_literal: true

class DuplicateCustomersController < ApplicationController
  def index
    orphans = ShoplineCustomer
      .where(shopline_id: [nil, ""])
      .where.not(full_name: [nil, ""])
      .order(:full_name, :id)
      .to_a

    officials_by_name = ShoplineCustomer
      .where.not(shopline_id: [nil, ""])
      .where(full_name: orphans.map(&:full_name).uniq)
      .group_by(&:full_name)

    @pairs = orphans.filter_map do |orphan|
      candidates = (officials_by_name[orphan.full_name] || []).reject do |official|
        same_contact?(orphan, official)
      end

      { orphan: orphan, candidates: candidates } if candidates.any?
    end

    @summaries = load_summaries(@pairs.flat_map { |pair| [pair[:orphan], *pair[:candidates]] })
  end

  def merge
    orphan   = ShoplineCustomer.find(params[:orphan_id])
    official = ShoplineCustomer.find(params[:official_id])

    result = CustomerMergeService.new(orphan: orphan, official: official, merged_by: current_user&.email).call

    if result.success?
      redirect_to duplicate_customers_path,
        notice: "已將「#{official.full_name}」的孤兒記錄合併（轉移 #{result.reassigned_orders_count} 筆訂單）。消費分析快取將於背景重新整理，稍後再查看。"
    else
      redirect_to duplicate_customers_path, alert: "合併失敗：#{result.error}"
    end
  end

  private

  # 名字相同，但 email、手機都對不上 → 很可能是同一個人留了不同聯絡方式
  def same_contact?(a, b)
    same_email = a.email.present? &&
      ShoplineCustomer.normalize_email(a.email) == ShoplineCustomer.normalize_email(b.email)
    same_phone = a.mobile_phone.present? &&
      ShoplineCustomer.normalize_phone(a.mobile_phone) == ShoplineCustomer.normalize_phone(b.mobile_phone)

    same_email || same_phone
  end

  def load_summaries(customers)
    keys = customers.filter_map { |c| identity_key_for(c) }.uniq
    CustomerPurchaseSummary.where(identity_key: keys).index_by(&:identity_key)
  end

  def identity_key_for(customer)
    phone = customer.mobile_phone.to_s.strip
    return phone if phone.present?

    customer.email.to_s.strip.downcase.presence
  end

  helper_method :identity_key_for
end
