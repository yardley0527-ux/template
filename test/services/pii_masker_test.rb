# frozen_string_literal: true

require "test_helper"

class PiiMaskerTest < ActiveSupport::TestCase
  test "masks mobile and landline phone numbers" do
    assert_equal "電話[電話]", PiiMasker.mask("電話0988103909")
    assert_equal "號碼 [電話] 已確認", PiiMasker.mask("號碼 978871950 已確認")
    assert_equal "市話[電話]", PiiMasker.mask("市話02-27221234")
  end

  test "masks emails" do
    assert_equal "[email] 反應代謝錠無效", PiiMasker.mask("linlin02689@gmail.com 反應代謝錠無效")
  end

  test "masks Taiwan addresses" do
    masked = PiiMasker.mask("桃園市楊梅區金山街275巷26號8樓")
    assert_includes masked, "[地址]"
    assert_not_includes masked, "金山街"
  end

  test "masks common three-character names" do
    assert_equal "[客人] 生日禮物寄出", PiiMasker.mask("林庭羽 生日禮物寄出")
    assert_equal "補寄 [客人] 透明水壺", PiiMasker.mask("補寄 梁宸勻 透明水壺")
  end

  test "does not mask product names or department terms" do
    text = "美白圖卡已交檔、穀胱甘肽推播、清纖粉衛教、設計部協助"
    assert_equal text, PiiMasker.mask(text)
  end

  test "does not mask dates or counts" do
    text = "7/8 訂單出貨 13筆"
    assert_equal text, PiiMasker.mask(text)
  end
end
