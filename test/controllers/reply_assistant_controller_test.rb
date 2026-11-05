require "test_helper"

class ReplyAssistantControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  setup do
    admin_role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    sign_in User.create!(email: "reply@test.com", username: "reply", password: "password123", role: admin_role)
    @faq = Faq.create!(question: "PDRN 一天吃幾顆", answer: "每天 6 顆喔", faq_category: FaqCategory.create!(name: "測試"))
  end

  def run_job(result)
    original = IgInbox::Claude.method(:call)
    IgInbox::Claude.define_singleton_method(:call) { |*| result.respond_to?(:call) ? result.call : result }
    perform_enqueued_jobs
  ensure
    IgInbox::Claude.define_singleton_method(:call, original)
  end

  test "有相同答案時原文帶入" do
    post reply_assistant_index_path, params: { question: "PDRN 一天要吃幾顆" }
    run_job("match_ref" => "faq:#{@faq.id}", "draft" => "AI 改寫", "needs_human" => false, "human_reason" => "")
    d = ReplyDraft.last
    assert_equal "每天 6 顆喔", d.answer
    assert d.direct_match?
    get reply_assistant_index_path
    assert_includes response.body, "已核准答案"
  end

  test "敏感問題一定標人工確認，即使 AI 判斷不用" do
    post reply_assistant_index_path, params: { question: "我懷孕了 PDRN 一天可以吃幾顆" }
    run_job("match_ref" => "faq:#{@faq.id}", "draft" => "", "needs_human" => false, "human_reason" => "")
    d = ReplyDraft.last
    assert d.needs_human
    assert_equal "懷孕哺乳", d.human_reason
    assert_not d.direct_match?
  end

  test "AI 回傳候選以外的編號不採用" do
    post reply_assistant_index_path, params: { question: "PDRN 一天吃幾顆" }
    run_job("match_ref" => "faq:999999", "draft" => "草稿", "needs_human" => false, "human_reason" => "")
    assert_nil ReplyDraft.last.match_ref
    assert_equal "草稿", ReplyDraft.last.answer
  end

  test "核准草稿後存入知識庫，下一次會成為候選" do
    d = ReplyDraft.create!(question: "可以跟咖啡一起吃嗎", answer: "草稿", status: "pending")
    patch reply_assistant_path(d), params: { decision: "approve", final_answer: "建議間隔一小時喔" }
    assert_equal "approved", d.reload.status
    item = ReplyKnowledgeItem.last
    assert_equal "建議間隔一小時喔", item.answer
    assert_includes ReplyAssistant::Knowledge.candidates("可以跟咖啡一起吃嗎").map(&:ref), "item:#{item.id}"
  end

  test "引用舊答案且沒有修改時不重複存" do
    d = ReplyDraft.create!(question: "PDRN 幾顆", answer: "每天 6 顆喔", match_ref: "faq:#{@faq.id}", status: "pending")
    assert_no_difference("ReplyKnowledgeItem.count") do
      patch reply_assistant_path(d), params: { decision: "approve", final_answer: "每天 6 顆喔" }
    end
  end

  test "不採用不會存入知識庫，產生失敗會顯示原因" do
    d = ReplyDraft.create!(question: "問題", answer: "草稿", status: "pending")
    assert_no_difference("ReplyKnowledgeItem.count") { patch reply_assistant_path(d), params: { decision: "reject" } }
    assert_equal "rejected", d.reload.status

    post reply_assistant_index_path, params: { question: "會失敗" }
    run_job(-> { raise "API 錯誤" })
    assert_equal "failed", ReplyDraft.last.status
    get reply_assistant_index_path
    assert_includes response.body, "API 錯誤"
  end
end
