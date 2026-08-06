# frozen_string_literal: true

require "test_helper"

class CrmRepurchasePreflightCheckTest < ActiveSupport::TestCase
  test "回傳結構含 results/blockers/warnings" do
    report = CrmRepurchasePreflightCheck.call
    assert report[:results].is_a?(Array)
    assert report[:blockers].is_a?(Array)
    assert report[:warnings].is_a?(Array)
    assert report[:results].all? { |r| %i[pass warning blocker].include?(r.level) }
  end

  test "不寫入任何資料" do
    assert_no_difference [
      -> { CrmCustomerProductCycle.count },
      -> { CrmRepurchaseCycleConfig.count },
      -> { CrmLivestreamOutreachTask.count },
      -> { CrmProductAlias.count }
    ] do
      CrmRepurchasePreflightCheck.call
    end
  end

  test "缺週期設定的產品會被列為 warning，不是 blocker" do
    key = "preflight_#{SecureRandom.hex(4)}"
    CrmProduct.create!(key: key, label: "測試缺週期預檢品", status: "confirmed", sql_pattern: "product_name LIKE '%測試缺週期預檢品%'")

    report = CrmRepurchasePreflightCheck.call
    finding = report[:results].find { |r| r.label == "缺週期設定產品名稱" }
    assert_equal :warning, finding.level
    assert_includes finding.value, "測試缺週期預檢品"
  end

  test "必要資料表都存在時為 pass" do
    report = CrmRepurchasePreflightCheck.call
    finding = report[:results].find { |r| r.label == "必要資料表" }
    assert_equal :pass, finding.level
  end

  test "沒有任何管理者時回報 blocker" do
    Role.where(key: "admin").destroy_all
    User.update_all(role_id: nil)

    report = CrmRepurchasePreflightCheck.call
    finding = report[:results].find { |r| r.label == "可開啟回購頁面的使用者/角色數" }
    assert_equal :blocker, finding.level
    assert_includes report[:blockers], finding
  end
end
