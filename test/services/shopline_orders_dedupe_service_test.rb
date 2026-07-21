# frozen_string_literal: true

require "test_helper"

class ShoplineOrdersDedupeServiceTest < ActiveSupport::TestCase
  def create_pair(order_number:, product_name: "薑黃6", checkout_amount: 10050,
                  quantity: 1, present_total: 15830, blank_total: nil,
                  import_run_a: 101, import_run_b: 102, email: "dup@example.com",
                  order_date: Time.zone.local(2026, 4, 1, 12))
    present = ShoplineOrder.create!(order_number: order_number, product_name: product_name,
                                    quantity: quantity, checkout_amount: checkout_amount,
                                    total_amount: present_total, payment_status: "已付款",
                                    order_date: order_date, import_run_id: import_run_a, email: email)
    blank = ShoplineOrder.create!(order_number: order_number, product_name: product_name,
                                  quantity: quantity, checkout_amount: checkout_amount,
                                  total_amount: blank_total, payment_status: "已付款",
                                  order_date: order_date, import_run_id: import_run_b, email: email)
    [present, blank]
  end

  # ── N+1 防護：discover 不應每組各查一次 ────────────────────────

  test "discover fetches candidate rows in one query, not one per group" do
    10.times { |i| create_pair(order_number: "#DN#{i}", product_name: "薑黃#{i}") }

    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      queries << payload[:sql] if payload[:sql].match?(/FROM "shopline_orders"/) && payload[:sql].include?("WHERE")
    end
    ShoplineOrdersDedupeService.call(apply: false)
    ActiveSupport::Notifications.unsubscribe(subscriber)

    # 10 組候選：應該只需要 1 次 "WHERE id IN (...)" 撈列查詢，
    # 不是每組各一次（否則會看到 10 次）。
    assert_operator queries.size, :<=, 1, "expected one batched fetch, got: #{queries}"
  end

  # ── 標準模式 A ──────────────────────────────────────────────────

  test "standard pattern A: identifies the NULL row as candidate, present row as keep" do
    present, blank = create_pair(order_number: "#D1")

    report = ShoplineOrdersDedupeService.call(apply: false)

    assert_equal 1, report[:candidate_delete_count]
    assert_equal 1, report[:affected_orders]
    assert_equal 1, report[:affected_customers]
    assert_equal false, report[:applied]
    assert_equal 2, ShoplineOrder.where(order_number: "#D1").count, "dry-run must not delete"
  end

  test "amount_impact sums the checkout_amount that would be double-counted, and proves total_amount impact is zero" do
    create_pair(order_number: "#D2", checkout_amount: 10050)
    create_pair(order_number: "#D3", checkout_amount: 3683)

    report = ShoplineOrdersDedupeService.call(apply: false)

    assert_equal BigDecimal("13733"), report[:amount_impact][:checkout_amount_sum_removed]
    assert_equal BigDecimal("0"), report[:amount_impact][:total_amount_sum_removed]
  end

  test "row_count_change reports the shopline_orders row delta" do
    create_pair(order_number: "#D2A")
    create_pair(order_number: "#D2B")

    report = ShoplineOrdersDedupeService.call(apply: false)

    assert_equal(-2, report[:row_count_change][:shopline_orders])
  end

  test "revenue_impact_by_year and by_month group candidates by the kept row's order_date" do
    create_pair(order_number: "#D2C", checkout_amount: 1000, order_date: Time.zone.local(2025, 6, 15))
    create_pair(order_number: "#D2D", checkout_amount: 2000, order_date: Time.zone.local(2026, 1, 10))

    report = ShoplineOrdersDedupeService.call(apply: false)

    assert_equal({ "2025" => BigDecimal("1000"), "2026" => BigDecimal("2000") }, report[:revenue_impact_by_year])
    assert_equal({ "2025-06" => BigDecimal("1000"), "2026-01" => BigDecimal("2000") }, report[:revenue_impact_by_month])
  end

  test "cache_impact counts distinct affected customers present in CPS/series-loyalty caches, no PII" do
    create_pair(order_number: "#D2E", email: "cache-impact@example.com")
    CustomerPurchaseSummary.create!(email: "cache-impact@example.com", identity_key: "cache-impact@example.com")
    CustomerSeriesLoyalty.create!(email: "cache-impact@example.com", series: "薑黃", order_count: 1,
                                  total_amount: 10050, first_date: Date.current, last_date: Date.current,
                                  days_since_last: 0, tier: "回購客")

    report = ShoplineOrdersDedupeService.call(apply: false)

    assert_equal 1, report[:cache_impact][:customer_purchase_summaries_customers_present]
    assert_equal 1, report[:cache_impact][:customer_series_loyalties_customers_present]
    assert_not_includes report[:cache_impact].to_s, "cache-impact@example.com"
    assert report[:cache_impact][:notes][:spending_rankings].present?
    assert report[:cache_impact][:notes][:livestream_d0_d3_attribution].present?
  end

  # ── total_amount 方向相反 ───────────────────────────────────────

  test "detects pattern A regardless of which row (older/newer id) holds total_amount" do
    present = ShoplineOrder.create!(order_number: "#D4", product_name: "私密粉1", quantity: 1,
                                    checkout_amount: 1980, total_amount: nil, payment_status: "已付款",
                                    order_date: Time.current, import_run_id: 1, email: "x@x.com")
    ShoplineOrder.create!(order_number: "#D4", product_name: "私密粉1", quantity: 1,
                         checkout_amount: 1980, total_amount: 8000, payment_status: "已付款",
                         order_date: present.order_date, import_run_id: 2, email: "x@x.com")

    report = ShoplineOrdersDedupeService.call(apply: false)

    assert_equal 1, report[:candidate_delete_count]
  end

  # ── 同 import_run 不刪 ──────────────────────────────────────────

  test "same import_run_id is not treated as pattern A" do
    create_pair(order_number: "#D5", import_run_a: 5, import_run_b: 5)

    report = ShoplineOrdersDedupeService.call(apply: false)

    assert_equal 0, report[:candidate_delete_count]
    assert_equal 1, report[:skipped_reasons]["same_import_run"]
  end

  # ── 不同 order_number 不刪 ──────────────────────────────────────

  test "identical content under different order_number is never grouped together" do
    create_pair(order_number: "#D6")
    create_pair(order_number: "#D7")

    report = ShoplineOrdersDedupeService.call(apply: false)

    assert_equal 2, report[:candidate_delete_count]
    assert_equal 2, report[:affected_orders]
  end

  # ── quantity / checkout_amount 不同不刪 ─────────────────────────

  test "different quantity within the same order_number is not grouped" do
    ShoplineOrder.create!(order_number: "#D8", product_name: "代謝錠1", quantity: 1,
                         checkout_amount: 1000, total_amount: 1000, payment_status: "已付款",
                         order_date: Time.current, import_run_id: 1, email: "a@a.com")
    ShoplineOrder.create!(order_number: "#D8", product_name: "代謝錠1", quantity: 2,
                         checkout_amount: 1000, total_amount: nil, payment_status: "已付款",
                         order_date: Time.current, import_run_id: 2, email: "a@a.com")

    report = ShoplineOrdersDedupeService.call(apply: false)

    assert_equal 0, report[:candidate_delete_count]
    assert_equal 2, ShoplineOrder.where(order_number: "#D8").count
  end

  test "different checkout_amount within the same order_number is not grouped" do
    ShoplineOrder.create!(order_number: "#D9", product_name: "代謝錠1", quantity: 1,
                         checkout_amount: 1000, total_amount: 1000, payment_status: "已付款",
                         order_date: Time.current, import_run_id: 1, email: "a@a.com")
    ShoplineOrder.create!(order_number: "#D9", product_name: "代謝錠1", quantity: 1,
                         checkout_amount: 1200, total_amount: nil, payment_status: "已付款",
                         order_date: Time.current, import_run_id: 2, email: "a@a.com")

    report = ShoplineOrdersDedupeService.call(apply: false)

    assert_equal 0, report[:candidate_delete_count]
  end

  # ── 三列以上複雜組跳過 ──────────────────────────────────────────

  test "groups with 3+ rows are skipped entirely, none deleted" do
    3.times do |i|
      ShoplineOrder.create!(order_number: "#D10", product_name: "薑黃6", quantity: 1,
                           checkout_amount: 10050, total_amount: i.zero? ? 15830 : nil,
                           payment_status: "已付款", order_date: Time.current,
                           import_run_id: 100 + i, email: "c@c.com")
    end

    report = ShoplineOrdersDedupeService.call(apply: false)

    assert_equal 0, report[:candidate_delete_count]
    assert_equal 1, report[:skipped_reasons]["group_size_not_2 (3 rows)"]
    assert_equal 3, ShoplineOrder.where(order_number: "#D10").count
  end

  # ── core 欄位不符跳過（both-present / both-blank / email 不符） ──

  test "both rows with total_amount present is not pattern A" do
    ShoplineOrder.create!(order_number: "#D11", product_name: "薑黃6", quantity: 1,
                         checkout_amount: 10050, total_amount: 15830, payment_status: "已付款",
                         order_date: Time.current, import_run_id: 1, email: "d@d.com")
    ShoplineOrder.create!(order_number: "#D11", product_name: "薑黃6", quantity: 1,
                         checkout_amount: 10050, total_amount: 16000, payment_status: "已付款",
                         order_date: Time.current, import_run_id: 2, email: "d@d.com")

    report = ShoplineOrdersDedupeService.call(apply: false)

    assert_equal 0, report[:candidate_delete_count]
    assert_equal 1, report[:skipped_reasons]["both_total_amount_present"]
  end

  test "both rows with total_amount blank is not pattern A" do
    create_pair(order_number: "#D12", present_total: nil)

    report = ShoplineOrdersDedupeService.call(apply: false)

    assert_equal 0, report[:candidate_delete_count]
    assert_equal 1, report[:skipped_reasons]["both_total_amount_blank"]
  end

  test "mismatched email between the pair is skipped as a core-field mismatch" do
    ShoplineOrder.create!(order_number: "#D13", product_name: "薑黃6", quantity: 1,
                         checkout_amount: 10050, total_amount: 15830, payment_status: "已付款",
                         order_date: Time.current, import_run_id: 1, email: "e1@x.com")
    ShoplineOrder.create!(order_number: "#D13", product_name: "薑黃6", quantity: 1,
                         checkout_amount: 10050, total_amount: nil, payment_status: "已付款",
                         order_date: Time.current, import_run_id: 2, email: "e2@x.com")

    report = ShoplineOrdersDedupeService.call(apply: false)

    assert_equal 0, report[:candidate_delete_count]
    assert_equal 1, report[:skipped_reasons]["core_fields_mismatch"]
  end

  # ── apply：刪除、備份、驗證 ─────────────────────────────────────

  test "apply deletes the NULL row, keeps the present row, and backs the deleted row up" do
    present, blank = create_pair(order_number: "#D14")

    report = ShoplineOrdersDedupeService.call(apply: true)

    assert_equal true, report[:applied]
    assert ShoplineOrder.exists?(present.id)
    assert_not ShoplineOrder.exists?(blank.id)

    backup = ShoplineOrdersDedupeBackup.find_by(original_id: blank.id)
    assert backup.present?
    assert_equal present.id, backup.kept_id
    assert_equal "#D14", backup.order_number
    assert_equal report[:dedupe_run_id], backup.dedupe_run_id
  end

  test "apply verification reports pattern_a_remaining as 0 and matches deleted count" do
    create_pair(order_number: "#D15")
    create_pair(order_number: "#D16")

    report = ShoplineOrdersDedupeService.call(apply: true)

    assert_equal 0, report[:verification][:pattern_a_remaining]
    assert_equal 2, report[:verification][:deleted_row_count]
    assert report[:verification][:kept_ids_still_present]
    assert report[:verification][:deleted_ids_gone]
  end

  test "dry-run does not write to shopline_orders_dedupe_backups" do
    create_pair(order_number: "#D17")

    ShoplineOrdersDedupeService.call(apply: false)

    assert_equal 0, ShoplineOrdersDedupeBackup.count
  end

  test "apply never touches skipped (pattern B/C) rows" do
    kept, gone = create_pair(order_number: "#D18") # pattern A, will be touched
    b1 = ShoplineOrder.create!(order_number: "#D19", product_name: "私密粉1", quantity: 1,
                              checkout_amount: 500, total_amount: 500, payment_status: "已付款",
                              order_date: Time.current, import_run_id: 1, email: "f@f.com")
    b2 = ShoplineOrder.create!(order_number: "#D20", product_name: "私密粉1", quantity: 1,
                              checkout_amount: 500, total_amount: 500, payment_status: "已付款",
                              order_date: Time.current, import_run_id: 1, email: "f@f.com")

    ShoplineOrdersDedupeService.call(apply: true)

    assert ShoplineOrder.exists?(kept.id)
    assert_not ShoplineOrder.exists?(gone.id)
    assert ShoplineOrder.exists?(b1.id)
    assert ShoplineOrder.exists?(b2.id)
  end

  # ── 冪等重跑 ─────────────────────────────────────────────────────

  test "running apply twice is idempotent — second run finds nothing" do
    create_pair(order_number: "#D21")

    first  = ShoplineOrdersDedupeService.call(apply: true)
    second = ShoplineOrdersDedupeService.call(apply: true)

    assert_equal 1, first[:candidate_delete_count]
    assert_equal 0, second[:candidate_delete_count]
  end

  # ── transaction rollback ────────────────────────────────────────

  test "a failure mid-apply rolls back the whole batch, deleting nothing" do
    create_pair(order_number: "#D22")
    create_pair(order_number: "#D23")

    original = ShoplineOrdersDedupeBackup.method(:insert_all!)
    ShoplineOrdersDedupeBackup.define_singleton_method(:insert_all!) do |*|
      raise ActiveRecord::StatementInvalid, "boom"
    end
    begin
      assert_raises(ActiveRecord::StatementInvalid) { ShoplineOrdersDedupeService.call(apply: true) }
    ensure
      ShoplineOrdersDedupeBackup.singleton_class.send(:remove_method, :insert_all!)
      ShoplineOrdersDedupeBackup.define_singleton_method(:insert_all!, original)
    end

    assert_equal 2, ShoplineOrder.where(order_number: "#D22").count
    assert_equal 2, ShoplineOrder.where(order_number: "#D23").count
    assert_equal 0, ShoplineOrdersDedupeBackup.count
  end

  # ── advisory lock ────────────────────────────────────────────────
  # Transactional tests share one AR connection/session, and Postgres session
  # advisory locks are re-entrant within the same session — so simulating
  # "another run holds the lock" requires a genuinely separate physical
  # connection, not just a second `ActiveRecord::Base.connection` call.

  test "apply aborts without touching data when the shared maintenance lock is held elsewhere" do
    create_pair(order_number: "#D24")

    db_config = ActiveRecord::Base.connection_db_config.configuration_hash
    other = PG.connect(dbname: db_config[:database], host: db_config[:host],
                       port: db_config[:port], user: db_config[:username],
                       password: db_config[:password])
    other.exec("SELECT pg_advisory_lock(hashtext('shopline_orders_write'))")
    begin
      report = ShoplineOrdersDedupeService.call(apply: true)
      assert report[:aborted]
      assert_equal 2, ShoplineOrder.where(order_number: "#D24").count
      assert_equal 0, ShoplineOrdersDedupeBackup.count
    ensure
      other.exec("SELECT pg_advisory_unlock(hashtext('shopline_orders_write'))")
      other.close
    end
  end

  test "dry-run does not need the lock and still reports while apply lock is held elsewhere" do
    create_pair(order_number: "#D25X")

    db_config = ActiveRecord::Base.connection_db_config.configuration_hash
    other = PG.connect(dbname: db_config[:database], host: db_config[:host],
                       port: db_config[:port], user: db_config[:username],
                       password: db_config[:password])
    other.exec("SELECT pg_advisory_lock(hashtext('shopline_orders_write'))")
    begin
      report = ShoplineOrdersDedupeService.call(apply: false)
      assert_not report[:aborted]
      assert_equal 1, report[:candidate_delete_count]
    ensure
      other.exec("SELECT pg_advisory_unlock(hashtext('shopline_orders_write'))")
      other.close
    end
  end

  # ── per_product breakdown ────────────────────────────────────────

  test "per_product breakdown classifies by JourneyProducts keyword" do
    create_pair(order_number: "#D25", product_name: "清纖粉2", checkout_amount: 3683)
    create_pair(order_number: "#D26", product_name: "薑黃6", checkout_amount: 10050)

    report = ShoplineOrdersDedupeService.call(apply: false)

    assert_equal 1, report[:per_product]["qingxian"]
    assert_equal 1, report[:per_product]["turmeric"]
  end
end
