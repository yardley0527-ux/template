# frozen_string_literal: true

require "test_helper"

class MessageListsMarkPurchasedTest < ActiveSupport::TestCase
  setup do
    @day = Date.new(2026, 11, 24)
    @upcoming = MessageList.create!(name: "未傳代謝錠", sent_on: @day + 1, target_product: "代謝錠", source: "manual")
    @sent = MessageList.create!(name: "已傳代謝錠", sent_on: @day, target_product: "代謝錠", source: "manual")
    @omni = MessageList.create!(name: "未傳全能", sent_on: @day + 1, target_product: "全能", source: "manual")
    [@upcoming, @sent, @omni].each do |l|
      l.recipients.create!(email: "buyer@example.com", full_name: "買家")
      l.recipients.create!(email: "other@example.com", full_name: "沒買")
    end
    order(email: " Buyer@Example.com ", product: "代謝錠2送1", status: "已付款", date: @day)
    order(email: "other@example.com", product: "代謝錠2送1", status: "未付款", date: @day)
  end

  test "marks buyers of the target product on lists not yet sent" do
    results = MessageLists::MarkPurchased.call(@day)

    assert_equal [@upcoming.id], results.map { |r| r[:list].id }
    assert_equal @day, @upcoming.recipients.find_by(email: "buyer@example.com").purchased_on
    assert_nil @upcoming.recipients.find_by(email: "other@example.com").purchased_on
    assert_nil @sent.recipients.find_by(email: "buyer@example.com").purchased_on
    assert_nil @omni.recipients.find_by(email: "buyer@example.com").purchased_on
  end

  test "keeps the earliest purchase date" do
    @upcoming.recipients.find_by(email: "buyer@example.com").update!(purchased_on: @day - 1)

    assert_empty MessageLists::MarkPurchased.call(@day)
    assert_equal @day - 1, @upcoming.recipients.find_by(email: "buyer@example.com").purchased_on
  end

  private

  def order(email:, product:, status:, date:)
    ShoplineOrder.create!(email: email, product_name: product, payment_status: status, order_date: Time.utc(date.year, date.month, date.day), # 匯入的 order_date 存 UTC 午夜
                          order_number: "##{SecureRandom.hex(4)}", customer_name: "x")
  end
end
