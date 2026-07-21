# frozen_string_literal: true

require "test_helper"

# 方案 B PR4 效能修正：BottleExtractor 原本每次 .call 都重新
# CrmProduct.find_by(key:)，在大量買家的情境（CustomerProductSnapshotService
# 逐 email 呼叫）造成嚴重 N+1（正式站量到單頁 1,063 次重複查詢）。
# 修正為 process 內按 product_key 快取，同一 key 只查一次。
class BottleExtractorCacheTest < ActiveSupport::TestCase
  test "repeated calls for the same product_key issue only one CrmProduct query" do
    key = "bottle_cache_test_#{SecureRandom.hex(4)}"
    CrmProduct.create!(key: key, label: "測試品", status: "confirmed", regex_pattern: "(\\d+)")
    BottleExtractor::REGEX_CACHE.delete(key)

    count = 0
    counter = ->(*, payload) { count += 1 if payload[:sql] =~ /crm_products/ }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      10.times { BottleExtractor.call("測試品3", key) }
    end

    assert_equal 1, count, "10 次呼叫應該只查一次 crm_products"
  ensure
    BottleExtractor::REGEX_CACHE.delete(key)
  end

  test "extraction result is unchanged by caching" do
    key = "bottle_cache_result_#{SecureRandom.hex(4)}"
    CrmProduct.create!(key: key, label: "測試品2", status: "confirmed", regex_pattern: "測試品2(\\d+)")
    BottleExtractor::REGEX_CACHE.delete(key)

    assert_equal 3, BottleExtractor.call("測試品23", key)
    assert_equal 3, BottleExtractor.call("測試品23", key) # 第二次走快取，結果應相同
  ensure
    BottleExtractor::REGEX_CACHE.delete(key)
  end

  test "unknown product_key still falls back to bracket pattern / default 1, cached as nil regex" do
    key = "bottle_cache_unknown_#{SecureRandom.hex(4)}"
    BottleExtractor::REGEX_CACHE.delete(key)

    assert_equal 1, BottleExtractor.call("無括號品名", key)
    assert_equal 5, BottleExtractor.call("有括號品名（5盒）", key)
  ensure
    BottleExtractor::REGEX_CACHE.delete(key)
  end
end
