# frozen_string_literal: true

require "test_helper"

# Phase 5：確認回購追蹤 Dashboard／直播候選名單／我的今日任務這三個 Phase 2-4
# 新頁面，沒有頁面權限的使用者在 sidebar 上看不到入口（不是只靠 controller
# 端的 authorize_page! 事後擋下來，避免使用者點了才發現 403）。
class SidebarEntryRepurchaseTest < ActiveSupport::TestCase
  REPURCHASE_TITLES = %w[回購追蹤\ Dashboard 直播回購候選名單 我的今日任務].freeze

  def crm_group_titles(user)
    group = SidebarEntry.visible_for(user).find { |g| g[:group_title] == "CRM" }
    group ? group[:children].map { |c| c[:title] } : []
  end

  test "三個回購追蹤入口都在 CRM 群組裡" do
    titles = SidebarEntry.all.find { |g| g[:group_title] == "CRM" }[:children].map { |c| c[:title] }
    REPURCHASE_TITLES.each { |t| assert_includes titles, t }
  end

  test "管理者看得到全部三個入口" do
    admin_role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    admin = User.create!(email: "sbadm@test.com", username: "sbadmin", password: "password123", role: admin_role)

    titles = crm_group_titles(admin)
    REPURCHASE_TITLES.each { |t| assert_includes titles, t }
  end

  test "沒有任何 PagePermission 的使用者看不到這三個入口" do
    nobody = User.create!(email: "sbnobody@test.com", username: "sbnobody", password: "password123")

    titles = crm_group_titles(nobody)
    REPURCHASE_TITLES.each { |t| assert_not_includes titles, t }
  end

  test "只拿到其中一個 controller 的 PagePermission，只會看到對應的那一個入口" do
    role = Role.create!(key: "sb_partial_#{SecureRandom.hex(4)}", name: "Partial")
    PagePermission.create!(role: role, controller_name: "crm_outreach_tasks")
    user = User.create!(email: "sbpartial@test.com", username: "sbpartial", password: "password123", role: role)

    titles = crm_group_titles(user)
    assert_includes titles, "我的今日任務"
    assert_not_includes titles, "回購追蹤 Dashboard"
    assert_not_includes titles, "直播回購候選名單"
  end
end
