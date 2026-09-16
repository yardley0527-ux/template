# frozen_string_literal: true

require "test_helper"

class WeeklyBriefingRegenerationJobTest < ActiveJob::TestCase
  setup do
    ENV["ANTHROPIC_API_KEY"] = "test-key"
  end

  teardown do
    ENV.delete("ANTHROPIC_API_KEY")
  end

  test "clears regeneration_started_at after a successful run" do
    briefing = WeeklyBriefing.create!(week_start: Date.new(2026, 6, 15), week_end: Date.new(2026, 6, 21),
                                       status: "success", regeneration_started_at: Time.current)

    stub_runner_call(->(week_start:) { [briefing, {}] }) do
      WeeklyBriefingRegenerationJob.perform_now("2026-06-15")
    end

    assert_nil briefing.reload.regeneration_started_at
  end

  test "still clears regeneration_started_at when WeeklyBriefingRunner raises, instead of leaving the UI stuck on 'generating'" do
    briefing = WeeklyBriefing.create!(week_start: Date.new(2026, 6, 15), week_end: Date.new(2026, 6, 21),
                                       status: "success", regeneration_started_at: Time.current)

    stub_runner_call(->(week_start:) { raise "boom" }) do
      assert_nothing_raised { WeeklyBriefingRegenerationJob.perform_now("2026-06-15") }
    end

    assert_nil briefing.reload.regeneration_started_at
  end

  test "accepts a Date argument as well as a string (ActiveJob may serialize/deserialize either)" do
    briefing = WeeklyBriefing.create!(week_start: Date.new(2026, 6, 15), week_end: Date.new(2026, 6, 21),
                                       status: "success", regeneration_started_at: Time.current)

    stub_runner_call(->(week_start:) { [briefing, {}] }) do
      WeeklyBriefingRegenerationJob.perform_now(Date.new(2026, 6, 15))
    end

    assert_nil briefing.reload.regeneration_started_at
  end

  private

  def stub_runner_call(replacement)
    original = WeeklyBriefingRunner.method(:call)
    WeeklyBriefingRunner.define_singleton_method(:call) { |week_start:, force_refresh: false| replacement.call(week_start: week_start) }
    yield
  ensure
    WeeklyBriefingRunner.define_singleton_method(:call, original)
  end
end
