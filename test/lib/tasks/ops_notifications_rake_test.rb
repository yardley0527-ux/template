# frozen_string_literal: true

require "test_helper"
require "rake"

class OpsNotificationsRakeTest < ActiveSupport::TestCase
  setup do
    unless $rake_tasks_loaded_for_tests
      Rails.application.load_tasks
      $rake_tasks_loaded_for_tests = true
    end
    Rake::Task["ops:notifications"].reenable
    @original_dry_run = ENV["DRY_RUN"]
    @original_rule = ENV["RULE"]
  end

  teardown do
    ENV["DRY_RUN"] = @original_dry_run
    ENV["RULE"] = @original_rule
  end

  test "DRY_RUN=1 runs every rule read-only and writes nothing" do
    ENV["DRY_RUN"] = "1"
    ENV.delete("RULE")
    notif_count = Notification.count
    sync_count = SyncRun.count

    output = capture_io { Rake::Task["ops:notifications"].invoke }.join

    assert_match(/DRY_RUN — no notifications\/sync_runs rows/, output)
    NotificationEngine::RULES.each_key { |category| assert_match(/#{category}: matched=/, output) }
    assert_equal notif_count, Notification.count
    assert_equal sync_count, SyncRun.count
  end

  test "DRY_RUN=1 with RULE scopes the preview to a single category" do
    ENV["DRY_RUN"] = "1"
    ENV["RULE"] = "system_health"

    output = capture_io { Rake::Task["ops:notifications"].invoke }.join

    assert_match(/system_health: matched=/, output)
    NotificationEngine::RULES.each_key do |category|
      next if category == "system_health"

      assert_no_match(/#{category}: matched=/, output)
    end
  end
end
