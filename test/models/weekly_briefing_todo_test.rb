# frozen_string_literal: true

require "test_helper"

class WeeklyBriefingTodoTest < ActiveSupport::TestCase
  def build_briefing
    WeeklyBriefing.create!(week_start: Date.new(2026, 6, 15), week_end: Date.new(2026, 6, 21), status: "success")
  end

  test "dedupe_key must be unique within the same briefing but can repeat across briefings" do
    briefing = build_briefing
    briefing.todos.create!(dedupe_key: "abc", title: "任務一")
    dup = briefing.todos.new(dedupe_key: "abc", title: "任務二")

    assert_not dup.valid?

    other_briefing = WeeklyBriefing.create!(week_start: Date.new(2026, 6, 22), week_end: Date.new(2026, 6, 28), status: "success")
    same_key_other_week = other_briefing.todos.new(dedupe_key: "abc", title: "任務三")
    assert same_key_other_week.valid?
  end

  test "mark_done! and reopen! toggle status and completed_at" do
    todo = build_briefing.todos.create!(dedupe_key: "k1", title: "任務")

    todo.mark_done!
    assert todo.done?
    assert todo.completed_at.present?

    todo.reopen!
    assert_not todo.done?
    assert_nil todo.completed_at
  end

  test "resolvable? is true only when target_query has a type" do
    briefing = build_briefing
    with_type = briefing.todos.create!(dedupe_key: "k2", title: "t", target_query: { "type" => "product_overdue" })
    without_type = briefing.todos.create!(dedupe_key: "k3", title: "t2", target_query: {})

    assert with_type.resolvable?
    assert_not without_type.resolvable?
  end
end
