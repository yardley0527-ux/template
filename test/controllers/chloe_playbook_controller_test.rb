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
    assert_equal 13, ChloePlaybookController.playbook["cards"].size
    assert_includes @response.body, "下單後關懷"
    assert_includes @response.body, "禁區清單"
    assert_includes @response.body, "疾病療效"
  end

  test "each product has its own tab and the general content stays on the first tab" do
    sign_in @admin
    get chloe_playbook_path(tab: "pdrn")
    assert_response :success
    assert_includes @response.body, "怎麼帶到組數"
    assert_includes @response.body, "是完整的皮膚新陳代謝45天到60天"
    assert_not_includes @response.body, "新客、一般會員的四步"
    %w[omni turmeric metabolic collagen whitening probiotic].each do |tab|
      get chloe_playbook_path(tab: tab)
      assert_response :success
      assert_includes @response.body, "這個產品的禁區"
    end
    get chloe_playbook_path(tab: "nope")
    assert_includes @response.body, "新客、一般會員的四步"
    assert_equal %w[全能 PDRN 薑黃 代謝錠 膠原蛋白 美白 益生菌], ChloePlaybookController.playbook["products"].map { |p| p["name"] }
    get chloe_playbook_path(tab: "probiotic")
    assert_includes @response.body, "壞菌調整、非常棒"
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
