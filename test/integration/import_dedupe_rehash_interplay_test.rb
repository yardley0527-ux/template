# frozen_string_literal: true

require "test_helper"
require "csv"
require "tempfile"
require Rails.root.join("lib/shopline_orders_dedupe_runner")

# End-to-end interplay between the new importer (content_hash without
# total_amount), ShoplineOrdersRehashService (migrates old-formula hashes)
# and ShoplineOrdersDedupeService (removes confirmed pattern-A duplicates).
# Unit tests for each piece live in their own files; this file exists to
# prove the THREE PIECES TOGETHER behave correctly on a shared dataset,
# which is a different risk than any one piece in isolation.
class ImportDedupeRehashInterplayTest < ActiveSupport::TestCase
  HEADERS = %w[訂單號碼 訂單日期 顧客 商品名稱 付款總金額 商品結帳價 數量 電話號碼 付款狀態 電郵 ig帳號 付款方式 會員等級 城市].freeze

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
         email: "interplay@example.com", date: "2026-01-15")
    [order_number, date, "測試客", product_name, total_amount, checkout_amount, quantity,
     "", "已付款", email, "", "信用卡", "一般會員", "台北"]
  end

  def seed_old_formula_pair(order_number:)
    old_hash = ->(total) do
      Digest::SHA256.hexdigest(JSON.generate(order_number: order_number, product_name: "薑黃6",
                                             quantity: 1, checkout_amount: "10050.0",
                                             total_amount: ShoplineOrder.format_decimal(total)))
    end
    present = ShoplineOrder.create!(order_number: order_number, product_name: "薑黃6", quantity: 1,
                                    checkout_amount: 10050, total_amount: 15830, payment_status: "已付款",
                                    order_date: Time.zone.local(2026, 4, 1), import_run_id: 501,
                                    email: "old@example.com", source_row_hash: old_hash.call(15830))
    blank = ShoplineOrder.create!(order_number: order_number, product_name: "薑黃6", quantity: 1,
                                  checkout_amount: 10050, total_amount: nil, payment_status: "已付款",
                                  order_date: Time.zone.local(2026, 4, 1), import_run_id: 502,
                                  email: "old@example.com", source_row_hash: old_hash.call(nil))
    [present, blank]
  end

  # 1) 歷史模式 A 尚未清理時，用新 importer 再匯入同一檔案
  test "scenario 1: re-importing before rehash creates a third row (documents why rehash must run first)" do
    order_number = "#I1"
    seed_old_formula_pair(order_number: order_number)

    import_csv([row(order_number: order_number, product_name: "薑黃6", checkout_amount: 10050, total_amount: 15830)])

    assert_equal 3, ShoplineOrder.where(order_number: order_number).count,
      "without rehash, the new importer's hash matches neither legacy row"
  end

  # 2) 歷史模式 A 清理後，用新 importer 再匯入同一檔案
  test "scenario 2: rehash + dedupe apply, then re-import matches the surviving row in place" do
    order_number = "#I2"
    seed_old_formula_pair(order_number: order_number)

    ShoplineOrdersRehashService.call(apply: true)
    ShoplineOrdersDedupeService.call(apply: true)
    assert_equal 1, ShoplineOrder.where(order_number: order_number).count, "cleanup should leave exactly one row"
    survivor_id = ShoplineOrder.find_by!(order_number: order_number).id

    import_csv([row(order_number: order_number, product_name: "薑黃6", checkout_amount: 10050, total_amount: 15830)])

    assert_equal 1, ShoplineOrder.where(order_number: order_number).count, "must update in place, not duplicate"
    assert_equal survivor_id, ShoplineOrder.find_by!(order_number: order_number).id
  end

  # 3/4) already covered in paid_orders_workbook_importer_test.rb — re-asserted
  # here in the same pipeline for completeness.
  test "scenario 3/4: total_amount oscillating present/blank across repeated imports never duplicates" do
    order_number = "#I3"
    import_csv([row(order_number: order_number, product_name: "私密粉1", checkout_amount: 1980, total_amount: 8000)])
    import_csv([row(order_number: order_number, product_name: "私密粉1", checkout_amount: 1980, total_amount: "")])
    import_csv([row(order_number: order_number, product_name: "私密粉1", checkout_amount: 1980, total_amount: 8000)])

    assert_equal 1, ShoplineOrder.where(order_number: order_number).count
  end

  # 5) 同訂單新增真正的新商品列
  test "scenario 5: a genuinely new product line added to an existing order creates one new row only" do
    order_number = "#I5"
    import_csv([row(order_number: order_number, product_name: "代謝錠1", checkout_amount: 1000, total_amount: 1000)])
    assert_equal 1, ShoplineOrder.where(order_number: order_number).count

    # 同一張訂單追加了另一個商品（真實情境：合併結帳/加購）
    import_csv([
      row(order_number: order_number, product_name: "代謝錠1", checkout_amount: 1000, total_amount: 1000),
      row(order_number: order_number, product_name: "薑黃1", checkout_amount: 900, total_amount: 1900)
    ])

    orders = ShoplineOrder.where(order_number: order_number)
    assert_equal 2, orders.count, "existing line updates in place, new line is added — never 3"
    assert_equal %w[代謝錠1 薑黃1], orders.order(:id).pluck(:product_name)
  end

  # 6) 同訂單相同商品但 quantity 改變 — documents a known, deliberate limitation
  test "scenario 6: a genuine quantity correction is NOT recognized as an edit of the same line (documented limitation)" do
    order_number = "#I6"
    import_csv([row(order_number: order_number, product_name: "益生菌1", checkout_amount: 1950, quantity: 1, total_amount: 1950)])
    assert_equal 1, ShoplineOrder.where(order_number: order_number).count

    # Shopline 端把這行的數量從 1 改成 2 後重新匯出（同一張訂單、同一商品，數量變了）
    import_csv([row(order_number: order_number, product_name: "益生菌1", checkout_amount: 1950, quantity: 2, total_amount: 1950)])

    orders = ShoplineOrder.where(order_number: order_number).order(:id)
    # quantity 是 identity 的一部分（刻意設計，見 content_hash 註解）：
    # 這裡不會被視為「同一列更新」，而是被當成第二條獨立線。這是為了不吞掉
    # 「同商品真的買了兩次、數量剛好不同」的情況所付出的已知代價 —— 需要
    # 這類「同商品數量修正」的案例交由 ShoplineOrdersDedupeService 之外的
    # 專案判斷（quantity 不同不在其安全刪除範圍內，見 dedupe 測試）。
    assert_equal 2, orders.count, "documents that quantity changes are NOT merged as an update"
  end

  # 7) 不同 order_number 短時間內購買相同商品（Pattern B）— dedupe 完全不動
  test "scenario 7: same-content different order_number lines survive both cleanup passes untouched" do
    a = ShoplineOrder.create!(order_number: "#I7A", product_name: "膠原蛋白1", quantity: 1,
                              checkout_amount: 2980, total_amount: 2980, payment_status: "已付款",
                              order_date: Time.current, import_run_id: 1, email: "same@example.com")
    b = ShoplineOrder.create!(order_number: "#I7B", product_name: "膠原蛋白1", quantity: 1,
                              checkout_amount: 2980, total_amount: 2980, payment_status: "已付款",
                              order_date: a.order_date + 9.minutes, import_run_id: 1, email: "same@example.com")

    ShoplineOrdersRehashService.call(apply: true)
    ShoplineOrdersDedupeService.call(apply: true)

    assert ShoplineOrder.exists?(a.id)
    assert ShoplineOrder.exists?(b.id)
  end

  # 目標驗證：不產生新的模式 A、不吞掉真實新訂單、不改動模式 B/C、重跑冪等。
  test "goal check: full pipeline (rehash -> dedupe -> reimport) does not create new pattern-A groups" do
    seed_old_formula_pair(order_number: "#I8")
    b = ShoplineOrder.create!(order_number: "#I9", product_name: "膠原蛋白1", quantity: 1,
                              checkout_amount: 2980, total_amount: 2980, payment_status: "已付款",
                              order_date: Time.current, import_run_id: 1, email: "goal@example.com")

    ShoplineOrdersRehashService.call(apply: true)
    ShoplineOrdersDedupeService.call(apply: true)
    import_csv([row(order_number: "#I8", product_name: "薑黃6", checkout_amount: 10050, total_amount: 15830)])

    post_report = ShoplineOrdersDedupeService.call(apply: false)
    assert_equal 0, post_report[:candidate_delete_count], "pipeline must not generate fresh pattern-A groups"
    assert ShoplineOrder.exists?(b.id), "pattern B/C row must survive untouched"
  end
end
