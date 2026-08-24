# frozen_string_literal: true

require "test_helper"

class CrmProductInventorySyncTest < ActiveSupport::TestCase
  def snapshot(rows)
    DandyInventorySnapshot.create!(snapshot_date: Date.current, synced_at: Time.current,
                                   data: { "supplements" => { "rows" => rows } })
  end

  def row(name:, values:, arrival: nil)
    { "name" => name, "values" => values, "arrival" => arrival }
  end

  test "no snapshot yet returns an error, does not raise" do
    result = CrmProductInventorySync.call
    assert_equal "no DandyInventorySnapshot yet", result[:error]
  end

  test "maps a known product name to its crm_products key and updates availability_status from zero stock" do
    CrmProduct.create!(key: "iced_tomato", label: "冰晶番茄", status: "confirmed", availability_status: "unknown")
    snapshot([row(name: "冰晶番茄", values: [41, nil, 32, 9, 0, nil, 0])])

    result = CrmProductInventorySync.call
    assert_nil result[:error]
    assert_equal 1, result[:updated].size
    assert_equal "out_of_stock", CrmProduct.find_by(key: "iced_tomato").availability_status
  end

  test "low but nonzero stock below the threshold becomes low_stock" do
    CrmProduct.create!(key: "astaxanthin", label: "蝦紅素", status: "confirmed", availability_status: "unknown")
    snapshot([row(name: "蝦紅素", values: [1, nil, 0, 0, 1, nil, 1])])

    CrmProductInventorySync.call
    assert_equal "low_stock", CrmProduct.find_by(key: "astaxanthin").availability_status
  end

  test "healthy stock becomes in_stock" do
    CrmProduct.create!(key: "collagen", label: "膠原蛋白", status: "confirmed", availability_status: "out_of_stock")
    snapshot([row(name: "膠原蛋白", values: [0, 1520, 188, 60, 1272, 1442, 2714])])

    CrmProductInventorySync.call
    assert_equal "in_stock", CrmProduct.find_by(key: "collagen").availability_status
  end

  test "an unmapped product name is skipped, not guessed at" do
    CrmProduct.create!(key: "glutathione", label: "穀胱甘肽", status: "confirmed", availability_status: "unknown")
    snapshot([row(name: "上錠下液", values: [247, nil, 200, 47, 247, nil, 247])])

    result = CrmProductInventorySync.call
    assert_includes result[:unmapped_names], "上錠下液"
    assert_equal "unknown", CrmProduct.find_by(key: "glutathione").availability_status, "must not guess at an ambiguous name mapping"
  end

  test "a parseable arrival date sets expected_restock_date" do
    CrmProduct.create!(key: "vitamin_dk_calcium", label: "維DK鈣", status: "confirmed", availability_status: "unknown")
    snapshot([row(name: "維生素D+鈣", values: [0, nil, 0, 0, 0, nil, 0], arrival: "預定 8/21 到貨")])

    CrmProductInventorySync.call
    product = CrmProduct.find_by(key: "vitamin_dk_calcium")
    assert_equal "out_of_stock", product.availability_status
    assert_equal Date.new(Date.current.year, 8, 21), product.expected_restock_date
  end

  test "does not touch a product whose status already matches (no spurious update/audit noise)" do
    CrmProduct.create!(key: "metabolism", label: "代謝錠", status: "confirmed", availability_status: "in_stock")
    snapshot([row(name: "代謝錠", values: [95, 300, 74, 21, 300, 939, 1239])])

    result = CrmProductInventorySync.call
    assert_empty result[:updated]
  end

  test "records a SyncRun for observability" do
    CrmProduct.create!(key: "collagen", label: "膠原蛋白", status: "confirmed", availability_status: "unknown")
    snapshot([row(name: "膠原蛋白", values: [0, 0, 0, 0, 0, 0, 2714])])

    assert_difference "SyncRun.count", 1 do
      CrmProductInventorySync.call
    end
    assert_equal "crm_product_inventory", SyncRun.last.source
    assert_equal "success", SyncRun.last.status
  end
end
