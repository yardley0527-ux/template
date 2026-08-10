# frozen_string_literal: true

require "test_helper"

class SidebarEntryLivestreamTest < ActiveSupport::TestCase
  def livestream_group
    SidebarEntry.all.find { |g| g[:group_title] == "直播管理" }
  end

  test "livestream management group has exactly 4 entries" do
    assert_equal 4, livestream_group[:children].size
  end

  test "new titles and hrefs are present" do
    titles_and_hrefs = livestream_group[:children].map { |c| [c[:title], c[:href]] }
    assert_includes titles_and_hrefs, ["直播成效總覽", Rails.application.routes.url_helpers.livestream_overview_path]
    assert_includes titles_and_hrefs, ["直播場次", Rails.application.routes.url_helpers.livestreams_path]
    assert_includes titles_and_hrefs, ["產品直播分析", Rails.application.routes.url_helpers.livestream_product_analysis_path]
    assert_includes titles_and_hrefs, ["直播策略", Rails.application.routes.url_helpers.livestream_strategy_path]
  end

  test "old per-product analysis entries are removed from sidebar" do
    titles = livestream_group[:children].map { |c| c[:title] }
    %w[直播歷史 直播分析\ -\ 全能 直播分析\ -\ 益生菌 直播分析\ -\ 品牌之夜總覽 直播分析\ -\ 薑黃 直播分析\ -\ 代謝錠 直播分析\ -\ 穀胱甘肽 直播策略報表].each do |old_title|
      assert_not_includes titles, old_title
    end
  end

  test "CRM group no longer has a broadcast/直播邀請管理 entry" do
    crm_group = SidebarEntry.all.find { |g| g[:group_title] == "CRM" }
    titles = crm_group[:children].map { |c| c[:title] }
    assert_not_includes titles, "直播邀請管理"
    assert_not_includes titles, "直播戰情室"
  end

  # ── visible_for：sidebar 過濾邏輯（權限資料本身怎麼來的，由遷移測試專門覆蓋）──

  test "admin sees all 4 livestream entries regardless of page_permissions" do
    admin_role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    admin = User.create!(email: "sidebar-admin@test.com", username: "sidebar_admin", password: "password123", role: admin_role)

    group = SidebarEntry.visible_for(admin).find { |g| g[:group_title] == "直播管理" }
    assert_equal 4, group[:children].size
  end

  test "role with only livestream_product_analysis permission sees only that one entry" do
    role = Role.create!(key: "sidebar-lpa-#{SecureRandom.hex(4)}", name: "LpaRole")
    PagePermission.create!(role: role, controller_name: "livestream_product_analysis")
    user = User.create!(email: "sidebar-lpa@test.com", username: "sidebar_lpa", password: "password123", role: role)

    group = SidebarEntry.visible_for(user).find { |g| g[:group_title] == "直播管理" }
    assert group, "應該看得到直播管理群組"
    titles = group[:children].map { |c| c[:title] }
    assert_includes titles, "產品直播分析"
    assert_not_includes titles, "直播成效總覽"
    assert_not_includes titles, "直播場次"
    assert_not_includes titles, "直播策略"
  end

  test "role with no livestream-related permission does not see the group at all" do
    role = Role.create!(key: "sidebar-none-#{SecureRandom.hex(4)}", name: "NoneRole")
    user = User.create!(email: "sidebar-none@test.com", username: "sidebar_none", password: "password123", role: role)

    group = SidebarEntry.visible_for(user).find { |g| g[:group_title] == "直播管理" }
    assert_nil group
  end
end
