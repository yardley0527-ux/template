# frozen_string_literal: true

require "test_helper"

class PrGiftTest < ActiveSupport::TestCase
  setup { @customer = ShoplineCustomer.create!(email: "pr-gift-model@example.com") }

  def build(attrs = {})
    @customer.pr_gifts.new({ product_name: "魚油", quantity: 1, unit: "瓶", given_on: Date.new(2026, 9, 30) }.merge(attrs))
  end

  test "欄位齊全就合法，summary 顯示產品與數量單位" do
    gift = build
    assert gift.valid?
    assert_equal "魚油 ×1瓶", gift.summary
  end

  test "必填欄位" do
    assert_not build(product_name: "").valid?
    assert_not build(given_on: nil).valid?
  end

  test "數量必須是 1–999 的整數" do
    assert_not build(quantity: 0).valid?
    assert_not build(quantity: 1000).valid?
    assert_not build(quantity: 1.5).valid?
    assert build(quantity: 999).valid?
  end

  test "單位只能是清單裡的" do
    assert_not build(unit: "箱").valid?
    PrGift::UNITS.each { |u| assert build(unit: u).valid?, u }
  end

  test "預設單位：膠原蛋白是盒，其他是瓶" do
    assert_equal "盒", PrGift.default_unit_for("膠原蛋白")
    assert_equal "瓶", PrGift.default_unit_for("薑黃")
    assert_equal "瓶", PrGift.default_unit_for("沒看過的產品")
  end

  test "刪除客人時一併刪除公關品紀錄" do
    build.save!
    assert_difference -> { PrGift.count }, -1 do
      @customer.destroy
    end
  end
end
