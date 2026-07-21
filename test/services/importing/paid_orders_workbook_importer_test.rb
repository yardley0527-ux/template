# frozen_string_literal: true

require "test_helper"
require "tempfile"
require "csv"

module Importing
  class PaidOrdersWorkbookImporterTest < ActiveSupport::TestCase
    HEADERS = %w[訂單號碼 訂單日期 顧客 商品名稱 付款總金額 商品結帳價 數量 電話號碼 付款狀態 電郵 ig帳號 付款方式 會員等級 城市].freeze

    # Roo dispatches by file extension; .csv routes through Roo::CSV, which
    # is enough to exercise the importer's row loop without needing an
    # xlsx-writing gem. Sheet name comes back as "default" (non-numeric), so
    # every call passes source_month: explicitly. Proper CSV quoting matters
    # here — a naive comma-join would corrupt fields like "2,670".
    def import_csv(rows, source_month: 1, source_year: 2026)
      file = Tempfile.new(["orders", ".csv"])
      file.write(CSV.generate_line(HEADERS))
      rows.each { |r| file.write(CSV.generate_line(r)) }
      file.flush

      Importing::PaidOrdersWorkbookImporter.new(
        file_path: file.path, source_year: source_year, source_month: source_month, verbose: false
      ).call
    ensure
      file&.close
    end

    def row(order_number:, product_name:, checkout_amount:, total_amount: "", quantity: 1,
           email: "shadow@example.com", date: "2026-01-15")
      [order_number, date, "測試客", product_name, total_amount, checkout_amount, quantity,
       "", "已付款", email, "", "信用卡", "一般會員", "台北"]
    end

    test "total_amount present-then-blank across imports does not create a duplicate row" do
      order_number = "#20260115120000001"
      import_csv([row(order_number: order_number, product_name: "清纖粉2",
                      checkout_amount: 3683, total_amount: 15900)])
      assert_equal 1, ShoplineOrder.where(order_number: order_number).count

      # 較新匯出：同一列，total_amount 變空白（模式 A 的真實觸發條件）
      import_csv([row(order_number: order_number, product_name: "清纖粉2",
                      checkout_amount: 3683, total_amount: "")])

      orders = ShoplineOrder.where(order_number: order_number)
      assert_equal 1, orders.count, "expected the second import to update, not duplicate"
      # 既有非空值不被空白覆蓋（payload.compact 保留舊值）
      assert_equal BigDecimal("15900"), orders.first.total_amount
    end

    test "total_amount blank-then-present across imports fills in the value on the same row" do
      order_number = "#20260115120000002"
      import_csv([row(order_number: order_number, product_name: "私密粉1",
                      checkout_amount: 1980, total_amount: "")])
      assert_nil ShoplineOrder.find_by(order_number: order_number).total_amount

      import_csv([row(order_number: order_number, product_name: "私密粉1",
                      checkout_amount: 1980, total_amount: 8000)])

      orders = ShoplineOrder.where(order_number: order_number)
      assert_equal 1, orders.count
      assert_equal BigDecimal("8000"), orders.first.total_amount
    end

    test "checkout_amount formatting differences across imports do not duplicate" do
      order_number = "#20260115120000003"
      import_csv([row(order_number: order_number, product_name: "代謝錠1", checkout_amount: 2670)])
      import_csv([row(order_number: order_number, product_name: "代謝錠1", checkout_amount: "2,670")])
      import_csv([row(order_number: order_number, product_name: "代謝錠1", checkout_amount: "2670.0")])

      assert_equal 1, ShoplineOrder.where(order_number: order_number).count
    end

    test "quantity formatting differences across imports do not duplicate" do
      order_number = "#20260115120000004"
      import_csv([row(order_number: order_number, product_name: "益生菌1", checkout_amount: 1950, quantity: 2)])
      import_csv([row(order_number: order_number, product_name: "益生菌1", checkout_amount: 1950, quantity: "2")])

      assert_equal 1, ShoplineOrder.where(order_number: order_number).count
    end

    test "different products in the same order create separate rows, not merged" do
      order_number = "#20260115120000005"
      import_csv([
        row(order_number: order_number, product_name: "代謝錠1", checkout_amount: 1000),
        row(order_number: order_number, product_name: "薑黃1", checkout_amount: 1200)
      ])

      assert_equal 2, ShoplineOrder.where(order_number: order_number).count
    end

    test "genuinely repeated identical lines within one order are both kept, not swallowed" do
      order_number = "#20260115120000006"
      import_csv([
        row(order_number: order_number, product_name: "清纖粉2", checkout_amount: 3683),
        row(order_number: order_number, product_name: "清纖粉2", checkout_amount: 3683)
      ])

      assert_equal 2, ShoplineOrder.where(order_number: order_number).count
    end

    test "same content under different order_number is never merged" do
      import_csv([
        row(order_number: "#20260115120000007", product_name: "膠原蛋白1", checkout_amount: 2980),
        row(order_number: "#20260115120000008", product_name: "膠原蛋白1", checkout_amount: 2980)
      ])

      assert_equal 1, ShoplineOrder.where(order_number: "#20260115120000007").count
      assert_equal 1, ShoplineOrder.where(order_number: "#20260115120000008").count
    end

    test "re-importing the identical file twice is idempotent" do
      rows = [
        row(order_number: "#20260115120000009", product_name: "全能3", checkout_amount: 3200, total_amount: 3200),
        row(order_number: "#20260115120000009", product_name: "薑黃1", checkout_amount: 900)
      ]
      import_csv(rows)
      before = ShoplineOrder.count
      import_csv(rows)

      assert_equal before, ShoplineOrder.count
    end

    test "a repeated line's occurrence assignment stays stable across re-imports of the same file" do
      order_number = "#20260115120000010"
      rows = [
        row(order_number: order_number, product_name: "穀胱甘肽1", checkout_amount: 1980),
        row(order_number: order_number, product_name: "穀胱甘肽1", checkout_amount: 1980)
      ]
      import_csv(rows)
      first_pass_ids = ShoplineOrder.where(order_number: order_number).order(:id).pluck(:id)

      import_csv(rows)
      second_pass_ids = ShoplineOrder.where(order_number: order_number).order(:id).pluck(:id)

      assert_equal first_pass_ids, second_pass_ids
      assert_equal 2, second_pass_ids.size
    end

    test "old pre-migration hash rows are not matched by the new formula (documents the compat gap)" do
      # 模擬正式站現有的舊資料：用「已移除」的舊公式（含 total_amount）算出的 hash。
      old_hash = Digest::SHA256.hexdigest(
        JSON.generate(order_number: "#20260115120000011", product_name: "薑黃6",
                      quantity: 1, checkout_amount: "10050.0", total_amount: "15830.0")
      )
      ShoplineOrder.create!(order_number: "#20260115120000011", product_name: "薑黃6",
                            quantity: 1, checkout_amount: 10050, total_amount: 15830,
                            payment_status: "已付款", order_date: 5.days.ago,
                            source_row_hash: old_hash)

      import_csv([row(order_number: "#20260115120000011", product_name: "薑黃6",
                      checkout_amount: 10050, total_amount: 15830)])

      # 新公式算出的 hash 找不到舊列 → 目前會多一列。這正是需要先跑
      # rehash 遷移任務的原因，見 ShopelineOrders::RehashContentIdentity。
      assert_equal 2, ShoplineOrder.where(order_number: "#20260115120000011").count,
        "documents pre-fix state: rehash migration is required before deploying this importer"
    end
  end
end
