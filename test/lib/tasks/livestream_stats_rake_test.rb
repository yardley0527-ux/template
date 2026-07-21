# frozen_string_literal: true

require "test_helper"
require "rake"

class LivestreamStatsRakeTest < ActiveSupport::TestCase
  setup do
    unless $rake_tasks_loaded_for_tests
      Rails.application.load_tasks
      $rake_tasks_loaded_for_tests = true
    end
    Rake::Task["livestreams:stats:refresh"].reenable
    @original_date_env = ENV["DATE"]
  end

  teardown do
    ENV["DATE"] = @original_date_env
  end

  test "refresh task with no DATE refreshes all events" do
    ENV.delete("DATE")
    a = Livestream.create!(date: Date.new(2033, 1, 1))
    b = Livestream.create!(date: Date.new(2033, 1, 8))

    silence_stream_output { Rake::Task["livestreams:stats:refresh"].invoke }

    assert a.reload.stats_refreshed_at.present?
    assert b.reload.stats_refreshed_at.present?
  end

  test "refresh task with DATE refreshes only that event" do
    a = Livestream.create!(date: Date.new(2033, 2, 1))
    b = Livestream.create!(date: Date.new(2033, 2, 8))
    ENV["DATE"] = "2033-02-01"

    silence_stream_output { Rake::Task["livestreams:stats:refresh"].invoke }

    assert a.reload.stats_refreshed_at.present?
    assert_nil b.reload.stats_refreshed_at
  end

  private

  def silence_stream_output
    original_stdout = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = original_stdout
  end
end
