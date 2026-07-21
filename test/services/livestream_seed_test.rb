# frozen_string_literal: true

require "test_helper"

# 測試 19：db/seeds/livestreams.rb 在空資料庫可執行，且日期修正已同步。
class LivestreamSeedTest < ActiveSupport::TestCase
  test "livestreams seed runs on empty db with corrected dates" do
    Livestream.destroy_all

    # seed 檔在頂層定義了 `p(name_with_price)` 輔助方法（會遮蔽 Kernel#p），
    # 測試載入後必須移除，避免污染同程序的其他測試。
    begin
      load Rails.root.join("db/seeds/livestreams.rb")
    ensure
      Object.send(:remove_method, :p) if Object.private_method_defined?(:p, false)
    end

    assert_equal 43, Livestream.count # seed 固定 43 場（正式站 45 = seed 43 + UI 新增 2 場）
    assert Livestream.unscoped.exists?(date: Date.parse("2025-11-21")), "seed 應含修正後日期 11/21"
    assert Livestream.unscoped.exists?(date: Date.parse("2025-12-05")), "seed 應含修正後日期 12/5"
    assert_not Livestream.unscoped.exists?(date: Date.parse("2025-11-22"))
    assert_not Livestream.unscoped.exists?(date: Date.parse("2025-12-07"))
    assert_operator LivestreamProduct.count, :>, 0
    assert_operator LivestreamGift.count, :>, 0
  end
end
