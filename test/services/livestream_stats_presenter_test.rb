# frozen_string_literal: true

require "test_helper"

class LivestreamStatsPresenterTest < ActiveSupport::TestCase
  def livestream!(attrs = {})
    Livestream.create!({ date: Date.new(2040, 1, 1), window_days: 3 }.merge(attrs))
  end

  test "level_rows returns all five levels in order with count/amount" do
    ls = livestream!(level_black_count: 2, level_black_amount: 500,
                     level_gold_count: 1, level_gold_amount: 300)
    rows = LivestreamStatsPresenter.level_rows(ls)
    assert_equal %w[黑卡 金卡 銀卡 白卡 一般會員], rows.map { |r| r[:name] }
    assert_equal 2, rows.find { |r| r[:name] == "黑卡" }[:count]
    assert_equal 500.to_d, rows.find { |r| r[:name] == "黑卡" }[:amount]
  end

  test "unmatched_buyers is total_buyers minus sum of level counts" do
    ls = livestream!(total_buyers: 10, level_black_count: 3, level_gold_count: 2)
    assert_equal 5, LivestreamStatsPresenter.unmatched_buyers(ls)
  end

  test "unmatched_revenue is total_revenue minus sum of level amounts" do
    ls = livestream!(total_revenue: 1000, level_black_amount: 400, level_gold_amount: 200)
    assert_equal 400.to_d, LivestreamStatsPresenter.unmatched_revenue(ls)
  end

  test "new_buyer_pct handles zero buyers without division error" do
    ls = livestream!(total_buyers: 0, new_buyers: 0)
    assert_equal 0.0, LivestreamStatsPresenter.new_buyer_pct(ls)
  end

  test "new_buyer_pct computes rounded percentage" do
    ls = livestream!(total_buyers: 200, new_buyers: 46)
    assert_equal 23.0, LivestreamStatsPresenter.new_buyer_pct(ls)
  end

  test "aov handles zero buyers" do
    ls = livestream!(total_buyers: 0, total_revenue: 0)
    assert_equal 0, LivestreamStatsPresenter.aov(ls)
  end

  test "never_refreshed? true when stats_refreshed_at is nil" do
    ls = livestream!(stats_refreshed_at: nil)
    assert LivestreamStatsPresenter.never_refreshed?(ls)
    ls.update!(stats_refreshed_at: Time.current)
    assert_not LivestreamStatsPresenter.never_refreshed?(ls)
  end

  test "provisional? true while today is within the window, false after" do
    within_window = livestream!(date: Date.current - 1, window_days: 3)
    assert LivestreamStatsPresenter.provisional?(within_window)

    past_window = livestream!(date: Date.current - 10, window_days: 3)
    assert_not LivestreamStatsPresenter.provisional?(past_window)
  end

  test "pct_change nil when previous is zero or blank, otherwise rounded percent" do
    assert_nil LivestreamStatsPresenter.pct_change(100, 0)
    assert_nil LivestreamStatsPresenter.pct_change(100, nil)
    assert_equal 25.0, LivestreamStatsPresenter.pct_change(125, 100)
    assert_equal(-10.0, LivestreamStatsPresenter.pct_change(90, 100))
  end
end
