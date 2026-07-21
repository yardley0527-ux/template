# frozen_string_literal: true

require "test_helper"

class RefreshLivestreamStatsJobTest < ActiveSupport::TestCase
  test "perform calls LivestreamStatsRefreshService and logs the resulting SyncRun" do
    ls = Livestream.create!(date: Date.new(2032, 1, 1))
    RefreshLivestreamStatsJob.new.perform
    assert ls.reload.stats_refreshed_at.present?
  end

  test "perform with date: refreshes only that event" do
    a = Livestream.create!(date: Date.new(2032, 2, 1))
    b = Livestream.create!(date: Date.new(2032, 2, 8))
    RefreshLivestreamStatsJob.new.perform(date: a.date)
    assert a.reload.stats_refreshed_at.present?
    assert_nil b.reload.stats_refreshed_at
  end

  test "perform runs synchronously (perform_now) and returns the SyncRun" do
    Livestream.create!(date: Date.new(2032, 3, 1))
    run = RefreshLivestreamStatsJob.new.perform
    assert_kind_of SyncRun, run
    assert_equal "livestream_stats", run.source
  end
end
