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

  def ai_result(reply: "寶貝 每天 6 顆喔", sources: [], conflicts: [], needs_human: false, found: true)
    { "found" => found, "reply" => reply, "sources" => sources, "conflicts" => conflicts, "needs_human" => needs_human, "human_reason" => "" }
  end

  test "組成回覆並附上原文依據，等確認" do
    post reply_assistant_index_path, params: { question: "PDRN 一天要吃幾顆" }
    run_job(ai_result(sources: [{ "ref" => "faq:#{@faq.id}", "quote" => "每天 6 顆" }]))
    d = ReplyDraft.last
    assert_equal "pending", d.status
    assert_equal "寶貝 每天 6 顆喔", d.answer
    assert_equal [{ "ref" => "faq:#{@faq.id}", "question" => "PDRN 一天吃幾顆", "quote" => "每天 6 顆" }], d.sources
    get reply_assistant_index_path
    assert_includes response.body, "依據（Chloe 已核准的回答，原文）"
    assert_includes response.body, "複製回覆"
  end

  test "不是答案原文或不在候選裡的引用都不採用" do
    post reply_assistant_index_path, params: { question: "PDRN 一天吃幾顆" }
    run_job(ai_result(sources: [{ "ref" => "faq:#{@faq.id}", "quote" => "每天 8 顆" },
                                { "ref" => "faq:999999", "quote" => "每天 6 顆" }]))
    assert_empty ReplyDraft.last.sources
  end

  test "說法不同的回答附上說明" do
    other = ReplyKnowledgeItem.create!(question: "PDRN 怎麼吃", answer: "寶貝 一天 3 顆就好", source: "instagram", status: "approved")
    post reply_assistant_index_path, params: { question: "PDRN 一天吃幾顆" }
    run_job(ai_result(sources: [{ "ref" => "faq:#{@faq.id}", "quote" => "每天 6 顆" }],
                      conflicts: [{ "ref" => "item:#{other.id}", "quote" => "一天 3 顆就好", "note" => "顆數不同" }]))
    assert_equal "顆數不同", ReplyDraft.last.conflicts.first["note"]
    get reply_assistant_index_path
    assert_includes response.body, "說法不同的回答"
  end

  test "敏感問題一定標人工確認，即使 AI 判斷不用" do
    post reply_assistant_index_path, params: { question: "我懷孕了 PDRN 一天可以吃幾顆" }
    run_job(ai_result(sources: [{ "ref" => "faq:#{@faq.id}", "quote" => "每天 6 顆" }]))
    d = ReplyDraft.last
    assert d.needs_human
    assert_equal "懷孕哺乳", d.human_reason
  end

  test "資料庫沒有相關回答時，回覆留空請 Chloe 親自回覆" do
    post reply_assistant_index_path, params: { question: "PDRN 一天吃幾顆" }
    run_job(ai_result(found: false, reply: "AI 自己編的"))
    d = ReplyDraft.last
    assert d.no_answer?
    assert_equal "", d.answer
    assert d.needs_human
    get reply_assistant_index_path
    assert_includes response.body, "請 Chloe 親自回覆"
    assert_not_includes response.body, "AI 自己編的"

    post reply_assistant_index_path, params: { question: "PDRN 一天吃幾顆" }
    run_job(ai_result(sources: [{ "ref" => "faq:#{@faq.id}", "quote" => "編造的原文" }]))
    assert ReplyDraft.last.no_answer?, "沒有任何原文依據也算沒找到"

    post reply_assistant_index_path, params: { question: "完全無關的問題 qqq" }
    run_job(-> { raise "不應該打 API" })
    assert ReplyDraft.last.no_answer?, "沒有候選時不打 API"
  end

  test "產品別名也找得到：問瘦身粉會找到寫清纖粉的回答" do
    item = ReplyKnowledgeItem.create!(question: "清纖粉怎麼吃", answer: "飯前 15–30 分鐘吃一包", source: "ig_history", status: "approved")
    ReplyKnowledgeItem.create!(question: "全能怎麼吃", answer: "飯後吃", source: "ig_history", status: "approved")
    refs = ReplyAssistant::Knowledge.candidates("瘦身粉是飯前空腹吃沒錯吧").map(&:ref)
    assert_equal "item:#{item.id}", refs.first
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

    post reply_assistant_index_path, params: { question: "PDRN 一天吃幾顆（會失敗）" }
    run_job(-> { raise "API 錯誤" })
    assert_equal "failed", ReplyDraft.last.status
    get reply_assistant_index_path
    assert_includes response.body, "API 錯誤"
  end

  test "知識庫可以用產品和主題交叉篩選，移除後留在原條件" do
    item = ReplyKnowledgeItem.create!(question: "有肌瘤可以吃全能嗎", answer: "可以喔", source: "instagram", status: "approved")
    ReplyKnowledgeItem.create!(question: "有肌瘤可以吃 PDRN 嗎", answer: "可以", source: "instagram", status: "approved")
    ReplyKnowledgeItem.create!(question: "全能可以分期嗎", answer: "可以", source: "instagram", status: "approved")

    get reply_assistant_index_path(topic: "婦科", product: "全能膠囊")
    assert_includes response.body, "有肌瘤可以吃全能嗎"
    assert_not_includes response.body, "有肌瘤可以吃 PDRN 嗎"
    assert_not_includes response.body, "全能可以分期嗎"
    assert_includes response.body, "PDRN 1"
    assert_not_includes response.body, "修改"

    patch remove_item_reply_assistant_path(item), params: { topic: "婦科", product: "全能膠囊" }
    assert_equal "rejected", item.reload.status
    assert_includes response.location, "topic="
  end

  test "關鍵字搜尋問題和答案，忽略空白大小寫，可搭配篩選" do
    ReplyKnowledgeItem.create!(question: "淚溝可以改善嗎", answer: "可以參考 P D R N", source: "instagram", status: "approved")
    ReplyKnowledgeItem.create!(question: "全能怎麼吃", answer: "飯後吃", source: "instagram", status: "approved")

    get reply_assistant_index_path(q: "淚溝")
    assert_includes response.body, "淚溝可以改善嗎"
    assert_not_includes response.body, "全能怎麼吃"
    assert_includes response.body, "清除搜尋"

    get reply_assistant_index_path(q: "pdrn")
    assert_includes response.body, "淚溝可以改善嗎"

    get reply_assistant_index_path(q: "淚溝 飯後")
    assert_includes response.body, "符合 0 筆"

    get reply_assistant_index_path(q: "飯後", product: "全能膠囊")
    assert_includes response.body, "全能怎麼吃"
  end

  test "移除後機器人不再使用" do
    item = ReplyKnowledgeItem.create!(question: "舊活動", answer: "舊答案", source: "instagram", status: "approved")
    patch remove_item_reply_assistant_path(item)
    assert_equal "rejected", item.reload.status
    assert_not_includes ReplyAssistant::Knowledge.all.map(&:ref), "item:#{item.id}"
  end

  test "標籤先看問題，健康主題不看答案，一筆可以有多個標籤" do
    c = ReplyAssistant::Category
    assert_equal %w[PDRN 全能膠囊], c.products("PDRN 跟全能可以一起吃嗎")
    assert_includes c.topics("有肌瘤可以吃嗎"), "婦科"
    assert_includes c.topics("有變瘦的產品嗎"), "瘦身體重"
    assert_includes c.topics("好的", "放在白天第一餐的飯後"), "吃法與搭配"
    assert_not_includes c.topics("好的", "我們沒有雌激素"), "婦科"
    assert_not_includes c.topics("低密度脂肪超標"), "瘦身體重"
    assert_empty c.topics("哈哈", "謝謝")
  end

  test "IG 歷史問答可當知識使用，頁面可切換到 IG 私訊整理" do
    item = ReplyKnowledgeItem.create!(question: "代謝錠可以泡水嗎（2026-01-28）", answer: "冷水，至少 500cc", source: "ig_history", status: "approved")
    assert_includes ReplyAssistant::Knowledge.all.map(&:ref), "item:#{item.id}"

    get reply_assistant_index_path
    assert_response :success
    assert_includes response.body, ig_reviews_path
  end

  test "回覆助手可以單獨開，其他 AI 功能維持暫停" do
    original = ENV.to_h.slice("AI_REPORTS_ENABLED", "REPLY_ASSISTANT_ENABLED")
    ENV.delete("AI_REPORTS_ENABLED")
    ENV["REPLY_ASSISTANT_ENABLED"] = "1"
    assert_not AiReports.paused?(:reply_assistant)
    assert AiReports.paused?
  ensure
    %w[AI_REPORTS_ENABLED REPLY_ASSISTANT_ENABLED].each { |k| original.key?(k) ? ENV[k] = original[k] : ENV.delete(k) }
  end
end
