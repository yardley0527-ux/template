require "test_helper"

class IgQuestionsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    sign_in User.create!(email: "ig_questions@test.com", username: "ig_questions", password: "password123", role: admin_role)
    @q = IgQuestion.create!(account_key: "chloe.chao", sheet_row: 2, ig_username: "anyu.wang", question: "懷孕可以吃嗎",
                            asked_at: Time.zone.parse("2026-11-01 10:00"), category: "產品功效／適合誰", sensitive: true, sensitive_reason: "懷孕")
    IgQuestionDigest.create!(day: Date.new(2026, 11, 1), status: "done", overview: "共 1 則。",
                             suggestions: [{ "title" => "懷孕可不可以吃", "detail" => "1 則在問" }], generated_at: Time.current)
  end

  test "顯示當天整理、類別、敏感問題與清單" do
    get ig_questions_path(day: "2026-11-01")
    assert_response :success
    assert_includes response.body, "共 1 則。"
    assert_includes response.body, "懷孕可不可以吃"
    assert_includes response.body, "產品功效／適合誰"
    assert_includes response.body, "要真人回"
    assert_includes response.body, "@anyu.wang"
  end

  test "沒指定日期時看最近有問題的那天" do
    get ig_questions_path
    assert_includes response.body, "共 1 則。"
  end

  test "改處理狀態" do
    patch ig_question_path(@q), params: { status: "handled" }
    assert_equal "handled", @q.reload.status
  end

  test "重新整理改背景執行" do
    assert_enqueued_with(job: IgQuestionDigestJob, args: ["2026-11-01"]) do
      post regenerate_ig_questions_path(day: "2026-11-01")
    end
    assert_equal "pending", IgQuestionDigest.find_by(day: Date.new(2026, 11, 1)).status
  end
end
