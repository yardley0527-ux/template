# frozen_string_literal: true

require "test_helper"

class SpendingRankingsHelperTest < ActionView::TestCase
  include SpendingRankingsHelper

  # ── YoY 顯示 ──────────────────────────────────────────

  test "YoY 成長率格式：正負號與一位小數" do
    up = { amount_2025_ytd: 35_000, amount_2026: 38_000, yoy_change: 3000, yoy_rate: 8.6 }
    assert_equal "+8.6%", yoy_rate_display(up)

    down = { amount_2025_ytd: 10_000, amount_2026: 5680, yoy_change: -4320, yoy_rate: -43.2 }
    assert_equal "-43.2%", yoy_rate_display(down)

    flat = { amount_2025_ytd: 10_000, amount_2026: 10_000, yoy_change: 0, yoy_rate: 0.0 }
    assert_equal "0.0%", yoy_rate_display(flat)
  end

  test "2025 同期為 0：兩期皆 0 顯示 —，2026 有消費顯示 NEW 而非無限大" do
    none = { amount_2025_ytd: 0, amount_2026: 0, yoy_change: 0, yoy_rate: nil }
    assert_equal "—", yoy_rate_display(none)

    new_customer = { amount_2025_ytd: 0, amount_2026: 8000, yoy_change: 8000, yoy_rate: nil }
    assert_equal "NEW", yoy_rate_display(new_customer)
  end

  # ── 最近消費天數標籤 ───────────────────────────────────

  test "最近消費天數標籤" do
    assert_equal "今天", silent_days_label(0)
    assert_equal "1 天前", silent_days_label(1)
    assert_equal "15 天前", silent_days_label(15)
    assert_equal "60 天前", silent_days_label(60)
    assert_equal "84 天沒消費", silent_days_label(84)
    assert silent_alert?(61)
    assert_not silent_alert?(60)
  end

  # ── 排名變化 ──────────────────────────────────────────

  test "排名上升與下降" do
    assert_equal "↑ 67", rank_delta_display({ rank_2025: 88, rank_2026: 21 }).first
    assert_equal "↓ 6",  rank_delta_display({ rank_2025: 3, rank_2026: 9 }).first
    assert_equal "持平", rank_delta_display({ rank_2025: 5, rank_2026: 5 }).first
  end

  test "2025 無排名依動能顯示 NEW 或回流，2026 無排名顯示未進榜" do
    assert_equal "NEW",   rank_delta_display({ rank_2025: nil, rank_2026: 3, trend: :new }).first
    assert_equal "回流",  rank_delta_display({ rank_2025: nil, rank_2026: 3, trend: :returning }).first
    assert_equal "未進榜", rank_delta_display({ rank_2025: 7, rank_2026: nil }).first
  end

  test "金額差顯示千分位與正負號" do
    assert_equal "+NT$1,880,640", signed_nt(1_880_640)
    assert_equal "-NT$45,730", signed_nt(-45_730)
  end
end
