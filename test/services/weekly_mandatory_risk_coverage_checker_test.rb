# frozen_string_literal: true

require "test_helper"

class WeeklyMandatoryRiskCoverageCheckerTest < ActiveSupport::TestCase
  def topic(anchor_words:, problem_words:, label: "新客不足")
    { "topic_key" => "t", "label" => label, "anchor_words" => anchor_words, "problem_words" => problem_words, "evidence" => {} }
  end

  def report(biggest_risk_desc: nil, decision_text: nil, action_text: nil)
    {
      "executive_summary" => {
        "biggest_risk" => { "description" => biggest_risk_desc },
        "decisions" => decision_text ? [{ "current_situation" => decision_text }] : []
      },
      "action_items" => action_text ? [{ "action" => action_text }] : []
    }
  end

  test "covered when the anchor and a problem word both appear in biggest_risk" do
    t = topic(anchor_words: ["新客"], problem_words: %w[不足 下降])
    result = WeeklyMandatoryRiskCoverageChecker.call(ai_report: report(biggest_risk_desc: "新客人數較近4週平均下降70.6%"), mandatory_topics: [t])

    assert result["covered"]
    assert_empty result["uncovered_topics"]
  end

  test "covered when the topic is only mentioned inside a decision, not biggest_risk" do
    t = topic(anchor_words: ["新客"], problem_words: %w[不足 下降])
    result = WeeklyMandatoryRiskCoverageChecker.call(ai_report: report(biggest_risk_desc: "全能缺貨", decision_text: "新客人數明顯下降"), mandatory_topics: [t])

    assert result["covered"]
  end

  test "covered when the topic is only mentioned inside an AI action item" do
    t = topic(anchor_words: ["新客"], problem_words: %w[不足 下降])
    result = WeeklyMandatoryRiskCoverageChecker.call(ai_report: report(biggest_risk_desc: "全能缺貨", action_text: "檢查新客渠道，人數明顯不足"), mandatory_topics: [t])

    assert result["covered"]
  end

  test "not covered when the anchor word appears but no problem word does (positive framing should not count)" do
    t = topic(anchor_words: ["新客"], problem_words: %w[不足 下降])
    result = WeeklyMandatoryRiskCoverageChecker.call(ai_report: report(biggest_risk_desc: "新客營收較去年同週成長顯著"), mandatory_topics: [t])

    assert_not result["covered"]
    assert_equal 1, result["uncovered_topics"].size
  end

  test "not covered when neither anchor nor problem word appears anywhere" do
    t = topic(anchor_words: ["新客"], problem_words: %w[不足 下降])
    result = WeeklyMandatoryRiskCoverageChecker.call(ai_report: report(biggest_risk_desc: "全能缺貨疊加舊客回購下滑"), mandatory_topics: [t])

    assert_not result["covered"]
  end

  test "two mandatory topics both covered, one via biggest_risk and one via a decision" do
    t1 = topic(anchor_words: ["新客"], problem_words: %w[不足 下降], label: "新客不足")
    t2 = topic(anchor_words: ["全能"], problem_words: ["缺貨"], label: "全能缺貨")
    result = WeeklyMandatoryRiskCoverageChecker.call(
      ai_report: report(biggest_risk_desc: "全能缺貨疊加舊客回購下滑", decision_text: "新客人數明顯不足，建議加強拉新"),
      mandatory_topics: [t1, t2]
    )

    assert result["covered"], result["uncovered_topics"].inspect
  end

  test "an empty mandatory_topics list is trivially covered" do
    result = WeeklyMandatoryRiskCoverageChecker.call(ai_report: report(biggest_risk_desc: "全能缺貨"), mandatory_topics: [])
    assert result["covered"]
  end
end
