# frozen_string_literal: true

require "test_helper"

class ImportsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.create!(key: Role::ADMIN_KEY, name: "Admin")
    @admin = User.create!(email: "imports_admin@test.com", username: "imports_admin", password: "password123", role: admin_role)

    staff_role = Role.create!(key: "imports_staff", name: "Staff")
    @staff = User.create!(email: "imports_staff@test.com", username: "imports_staff", password: "password123", role: staff_role)
  end

  teardown do
    FileUtils.rm_rf(ImportsController::IMPORTS_DIR)
  end

  test "非 admin 不能存取上傳頁" do
    sign_in @staff
    get imports_path

    assert_redirected_to root_path
  end

  test "admin 可以看到上傳頁與最近匯入紀錄" do
    ImportRun.create!(kind: "paid_orders_workbook", file_name: "old.xlsx", file_checksum: SecureRandom.hex(16))
    sign_in @admin

    get imports_path

    assert_response :success
    assert_includes response.body, "old.xlsx"
  end

  test "admin 上傳已付款訂單檔案會排入 ImportPaidOrdersJob（暫存檔由 job 執行後負責清除）" do
    sign_in @admin
    file = fixture_file_upload_for("paid_orders.csv", "訂單號碼\n")

    assert_enqueued_with(job: ImportPaidOrdersJob) do
      post imports_path, params: { kind: "paid_orders", source_year: "2026", source_month: "8", file: file }
    end

    assert_redirected_to imports_path
    assert_equal 1, Dir.glob(ImportsController::IMPORTS_DIR.join("*")).size
  end

  test "年份缺漏時拒絕上傳已付款訂單" do
    sign_in @admin
    file = fixture_file_upload_for("paid_orders.csv", "訂單號碼\n")

    assert_no_enqueued_jobs do
      post imports_path, params: { kind: "paid_orders", source_year: "", file: file }
    end

    assert_redirected_to imports_path
    assert_empty Dir.glob(ImportsController::IMPORTS_DIR.join("*"))
  end

  test "admin 上傳顧客名單檔案會排入 ImportCustomersJob" do
    sign_in @admin
    file = fixture_file_upload_for("customers.csv", "姓名\n")

    assert_enqueued_with(job: ImportCustomersJob) do
      post imports_path, params: { kind: "customers_report", file: file }
    end

    assert_redirected_to imports_path
  end

  test "不允許的副檔名會被拒絕" do
    sign_in @admin
    file = fixture_file_upload_for("virus.exe", "not a spreadsheet")

    assert_no_enqueued_jobs do
      post imports_path, params: { kind: "paid_orders", source_year: "2026", file: file }
    end

    assert_redirected_to imports_path
  end

  test "status 回傳 JSON，含中文類型標籤與完成狀態" do
    done_run = ImportRun.create!(
      kind: "paid_orders_workbook", file_name: "done.xlsx", file_checksum: SecureRandom.hex(16),
      finished_at: Time.current, upserted_rows: 12, error_rows: 0
    )
    pending_run = ImportRun.create!(
      kind: "customers_report", file_name: "pending.csv", file_checksum: SecureRandom.hex(16)
    )
    sign_in @admin

    get status_imports_path

    assert_response :success
    json = JSON.parse(response.body)
    by_id = json.index_by { |r| r["id"] }

    assert_equal "已付款訂單", by_id[done_run.id]["kind_label"]
    assert_equal 12, by_id[done_run.id]["upserted_rows"]
    assert_not_nil by_id[done_run.id]["finished_at"]

    assert_equal "顧客名單", by_id[pending_run.id]["kind_label"]
    assert_nil by_id[pending_run.id]["finished_at"]
  end

  test "非 admin 不能打 status 端點" do
    sign_in @staff
    get status_imports_path

    assert_redirected_to root_path
  end

  private

  def fixture_file_upload_for(filename, content)
    tmp = Tempfile.new([File.basename(filename, ".*"), File.extname(filename)])
    tmp.write(content)
    tmp.rewind
    Rack::Test::UploadedFile.new(tmp.path, "text/csv", original_filename: filename)
  end
end
