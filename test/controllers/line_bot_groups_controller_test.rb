# frozen_string_literal: true

require "test_helper"

class LineBotGroupsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    @admin = User.create!(email: "line-admin@test.com", username: "line_admin", password: "password123", role: admin_role)
    @group = LineBotGroup.create!(group_id: "Cstrategy", name: "苼莛國際-策略部")
  end

  test "admin 勾選訂閱，不認得的項目丟掉，全部取消勾選就清空" do
    sign_in @admin
    get line_bot_groups_path
    assert_response :ok
    assert_includes response.body, "苼莛國際-策略部"
    assert_includes response.body, "沒有設定 LINE_REPORT_CHANNEL_ACCESS_TOKEN" # 測試環境沒有金鑰

    patch line_bot_group_path(@group), params: { line_bot_group: { subscriptions: ["", "order_brief", "bogus"] } }
    assert_equal ["order_brief"], @group.reload.subscriptions

    patch line_bot_group_path(@group), params: { line_bot_group: { subscriptions: [""] } }
    assert_equal [], @group.reload.subscriptions
  end
  test "按鈕在背景發一份前一天訂單簡報預覽；沒勾訂單簡報的群組不出現、也發不了" do
    sign_in @admin
    get line_bot_groups_path
    assert_not_includes response.body, "發一份前一天訂單簡報（測試）"
    assert_raises(ActiveRecord::RecordNotFound) { post preview_order_brief_line_bot_group_path(@group) }
    assert_no_enqueued_jobs only: OrderBriefPreviewJob

    @group.update!(subscriptions: ["order_brief"])
    get line_bot_groups_path
    assert_includes response.body, "發一份前一天訂單簡報（測試）"
    assert_enqueued_with(job: OrderBriefPreviewJob, args: [@group.id, (Date.current - 1).iso8601]) do
      post preview_order_brief_line_bot_group_path(@group)
    end
    assert_redirected_to line_bot_groups_path
  end

  test "補發報告：有勾匯入後報告才出現，選日期在背景補發，不合理的日期擋掉" do
    sign_in @admin
    get line_bot_groups_path
    assert_not_includes response.body, "補發報告"

    @group.update!(subscriptions: ["sales_daily"])
    get line_bot_groups_path
    assert_includes response.body, "補發報告"

    travel_to Time.zone.local(2026, 10, 27, 11) do
      assert_enqueued_with(job: LineReportResendJob, args: [@group.id, "2026-10-24", "2026-10-26"]) do
        post resend_reports_line_bot_group_path(@group), params: { from: "2026-10-24", to: "2026-10-26" }
      end
      assert_redirected_to line_bot_groups_path
      assert_match "10/24–10/26", flash[:notice]

      assert_no_enqueued_jobs only: LineReportResendJob do
        post resend_reports_line_bot_group_path(@group), params: { from: "2026-10-26", to: "2026-10-27" }
        post resend_reports_line_bot_group_path(@group), params: { from: "2026-10-26", to: "2026-10-24" }
        post resend_reports_line_bot_group_path(@group), params: { from: "2026-10-01", to: "2026-10-26" }
      end
      assert_match "一次最多補發 7 天", flash[:alert]
    end
  end
end
