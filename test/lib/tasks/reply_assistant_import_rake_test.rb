# frozen_string_literal: true

require "test_helper"
require "rake"

class ReplyAssistantImportRakeTest < ActiveSupport::TestCase
  setup do
    unless $rake_tasks_loaded_for_tests
      Rails.application.load_tasks
      $rake_tasks_loaded_for_tests = true
    end
    Rake::Task["reply_assistant:import_ig_history"].reenable
    @env = ENV.to_h.slice("FILE", "SYNC_STATUS")
    @file = Tempfile.new(["kb", ".jsonl"])
  end

  teardown do
    %w[FILE SYNC_STATUS].each { |k| @env.key?(k) ? ENV[k] = @env[k] : ENV.delete(k) }
    @file.close!
  end

  def write_rows(*rows)
    @file.rewind; @file.truncate(0)
    rows.each { |r| @file.puts(r.to_json) }
    @file.flush
    ENV["FILE"] = @file.path
  end

  test "new rows take the status from the file and default to approved" do
    write_rows({ question: "全能怎麼吃？（2026-11-01）", answer: "一天四顆" },
               { question: "孕婦能吃嗎（2026-11-02）", answer: "可以", status: "pending" },
               { question: "PDRN 何時到（2026-11-03）", answer: "一月底到貨", status: "rejected" })
    assert_output(/新增 3 筆/) { Rake::Task["reply_assistant:import_ig_history"].invoke }
    statuses = ReplyKnowledgeItem.where(source: "ig_history").pluck(:question, :status).to_h
    assert_equal "approved", statuses["全能怎麼吃？（2026-11-01）"]
    assert_equal "pending", statuses["孕婦能吃嗎（2026-11-02）"]
    assert_equal "rejected", statuses["PDRN 何時到（2026-11-03）"]
  end

  test "SYNC_STATUS only moves approved items to a more cautious status" do
    approved = ReplyKnowledgeItem.create!(question: "孕婦能吃嗎", answer: "可以", source: "ig_history", status: "approved")
    rejected = ReplyKnowledgeItem.create!(question: "狼瘡能吃嗎", answer: "可以", source: "ig_history", status: "rejected")
    write_rows({ question: "孕婦能吃嗎", answer: "可以", status: "pending" },
               { question: "狼瘡能吃嗎", answer: "可以", status: "approved" })
    ENV["SYNC_STATUS"] = "1"
    assert_output(/改狀態 1 筆/) { Rake::Task["reply_assistant:import_ig_history"].invoke }
    assert_equal "pending", approved.reload.status
    assert_equal "rejected", rejected.reload.status
  end
end
