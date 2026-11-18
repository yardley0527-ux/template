# frozen_string_literal: true

require "test_helper"

class ChloePlaybookControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    @admin = User.create!(email: "admin-pb@test.com", username: "admin_pb", password: "password123", role: admin_role)
  end

  test "shows steps, scenario cards with Chloe quotes and the forbidden list" do
    sign_in @admin
    get chloe_playbook_path
    assert_response :success
    assert_includes @response.body, "新客、一般會員的四步"
    assert_includes @response.body, "前提是寶貝有真的會持續吃喔，才可以讓你囤貨"
    assert_equal 26, ChloePlaybookController.playbook["cards"].size
    assert_includes @response.body, "留言 +1、IG 按鈕進來的新客"
    assert_includes @response.body, "上面沒分到的 57.8% 對話"
    assert_includes @response.body, "下單後關懷"
    assert_includes @response.body, "Chloe 怎麼看狀況調整建議"
    assert_includes @response.body, "我們用一個月來做一次體重的判定,不要利用一個禮拜,"
    assert_includes @response.body, "一律轉 Chloe"
    assert_includes @response.body, "禁區清單"
    assert_includes @response.body, 'href="#card-26"'
    assert_includes @response.body, 'id="card-26"'
    assert_includes @response.body, "疾病療效"
  end

  test "each product has its own tab and the general content stays on the first tab" do
    sign_in @admin
    get chloe_playbook_path(tab: "pdrn")
    assert_response :success
    assert_includes @response.body, "怎麼帶到組數"
    assert_includes @response.body, "是完整的皮膚新陳代謝45天到60天"
    assert_not_includes @response.body, "新客、一般會員的四步"
    %w[omni turmeric metabolic collagen whitening probiotic fish-oil astaxanthin cleanse intimate vitamin-d glutathione].each do |tab|
      get chloe_playbook_path(tab: tab)
      assert_response :success
      assert_includes @response.body, "這個產品的禁區"
    end
    get chloe_playbook_path(tab: "nope")
    assert_includes @response.body, "新客、一般會員的四步"
    assert_equal ["全能", "PDRN", "薑黃", "代謝錠", "膠原蛋白", "冰晶蕃茄（美白）", "益生菌", "魚油", "蝦紅素", "清纖粉", "私密粉", "維DK鈣", "穀胱甘肽"], ChloePlaybookController.playbook["products"].map { |p| p["name"] }
    get chloe_playbook_path(tab: "probiotic")
    assert_includes @response.body, "壞菌調整、非常棒"
    get chloe_playbook_path(tab: "cleanse")
    assert_includes @response.body, 'href="#faq-1"'
    assert_includes @response.body, 'id="sec-inconsistent"'
    assert_includes @response.body, "如果你忘記了 已經吃東西了 就不要補吃"
  end

  test "sidebar has its own 客服話術 group" do
    group = SidebarEntry.all.find { |g| g[:group_title] == "客服話術" }
    assert group
    assert_includes group[:children].map { |c| [c[:title], c[:href]] }, ["Chloe 話術卡", chloe_playbook_path]
  end

  test "roles without the page permission cannot open it" do
    role = Role.create!(key: "cs-pb", name: "客服")
    user = User.create!(email: "cs-pb@test.com", username: "cs_pb", password: "password123", role: role)
    sign_in user
    get chloe_playbook_path
    assert_not_equal 200, @response.status
  end
end
