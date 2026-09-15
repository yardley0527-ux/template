# frozen_string_literal: true

require "test_helper"

# 端到端證明「商品回購全部為0」的根因已經修正，而且歸戶邏輯本身是對的：
# - 同產品不同SKU（例如「XX3」跟「XX6」代表買3瓶跟買6瓶）要算同一個產品的回購
# - 組合商品（例如「XX1薑黃1」）要能歸戶回其中一個成分產品
# - 真的完全沒有人回購時，要老實顯示0，不能因為想避免顯示0就假造數字
# - 舊客有買、但商品回購比對結果為0時，要觸發資料異常防呆，不能直接得出
#   「沒有人回購」的經營結論
#
# 用的是正式產品比對機制本身（CrmProduct#sql_pattern 的子字串比對，
# CrmCustomerProductCycleBuilderService 也是用同一套規則），不是另外模擬一套。
class WeeklyRepurchaseAttributionTest < ActiveSupport::TestCase
  def unique_label
    "回購驗證品#{SecureRandom.hex(3)}"
  end

  def make_product(label)
    key = "repur_#{SecureRandom.hex(4)}"
    CrmProduct.create!(key: key, label: label, status: "confirmed",
                        sql_pattern: "product_name LIKE '%#{label}%'", regex_pattern: "#{label}(\\d+)")
    CrmRepurchaseCycleConfig.create!(product_key: key, bottle_count: 1, median_days: 30, source: "manual")
    key
  end

  def make_order(email:, product_name:, order_date:, amount: 500)
    ShoplineOrder.create!(order_number: "ATTR#{SecureRandom.hex(6)}", email: email, product_name: product_name,
                          order_date: order_date, payment_status: "已付款", quantity: 1, total_amount: amount)
  end

  test "a customer buying a different SKU of the same product this week counts as a repurchase" do
    label = unique_label
    key = make_product(label)
    period = WeeklyPeriod.new(Date.new(2026, 6, 15))
    email = "sku_#{SecureRandom.hex(4)}@example.com"

    make_order(email: email, product_name: "#{label}3", order_date: period.week_start - 90) # 買3瓶，很久以前
    make_order(email: email, product_name: "#{label}6", order_date: period.week_start + 2)  # 這週買6瓶（不同SKU）

    CrmCustomerProductCycleBuilderService.call(product_key: key)
    payload = WeeklyMetricsService.call(week_start: period.week_start)["product_repurchase"]["products"].find { |p| p["product_key"] == key }

    assert_equal 1, payload["repurchased_this_week"], "different SKU of the same product should still count as one repurchase"
  end

  test "a combo order containing the product this week correctly attributes to that product's repurchase" do
    label = unique_label
    key = make_product(label)
    period = WeeklyPeriod.new(Date.new(2026, 6, 15))
    email = "combo_#{SecureRandom.hex(4)}@example.com"

    make_order(email: email, product_name: "#{label}3", order_date: period.week_start - 90)
    make_order(email: email, product_name: "#{label}1薑黃1", order_date: period.week_start + 2) # 組合商品

    CrmCustomerProductCycleBuilderService.call(product_key: key)
    payload = WeeklyMetricsService.call(week_start: period.week_start)["product_repurchase"]["products"].find { |p| p["product_key"] == key }

    assert_equal 1, payload["repurchased_this_week"], "a combo order containing this product's name should still attribute the repurchase"
  end

  test "when there genuinely is no repurchase this week, the report shows a real 0, not a fabricated non-zero number" do
    label = unique_label
    key = make_product(label)
    period = WeeklyPeriod.new(Date.new(2026, 6, 15))
    email = "norepeat_#{SecureRandom.hex(4)}@example.com"

    # first_date 落在本週，讓這個人被分類成「新客」而不是「舊客回購」——這樣
    # this_week.returning_customers 才會是0，不會誤觸「舊客>0但商品回購=0」
    # 的矛盾防呆（那個防呆是設計給「有其他舊客活動、但商品回購比對莫名全掛零」
    # 的情境，不該在單純「這產品這週剛好沒有人回購」時也一起蓋牌）。
    CustomerPurchaseSummary.create!(identity_key: "id_#{email}", email: email, first_date: period.week_start + 1,
                                     purchase_count: 1, silent_only: false, silent_days_threshold: 45)
    make_order(email: email, product_name: "#{label}3", order_date: period.week_start + 1) # 首購，本週才第一次買

    CrmCustomerProductCycleBuilderService.call(product_key: key)
    payload = WeeklyMetricsService.call(week_start: period.week_start)["product_repurchase"]["products"].find { |p| p["product_key"] == key }

    assert_equal 0, payload["repurchased_this_week"]
    assert_not payload["cycles_stale"]
  end

  test "a stale product (no cycle rows built yet) shows nil, not a fabricated zero" do
    label = unique_label
    key = make_product(label)
    period = WeeklyPeriod.new(Date.new(2026, 6, 15))

    # 故意不呼叫 CrmCustomerProductCycleBuilderService——模擬排程還沒跑過、
    # crm_customer_product_cycles 完全沒有這個產品的資料。
    payload = WeeklyMetricsService.call(week_start: period.week_start)["product_repurchase"]
    product = payload["products"].find { |p| p["product_key"] == key }

    assert product["cycles_stale"], "no cycle rows exist yet for this product, so it must be treated as stale, not as a confirmed zero"
    assert_nil product["repurchased_this_week"], "must show nil (資料不足) rather than 0 when the underlying data can't be trusted"
  end

  test "when cycles are fresh but genuinely show 0 repurchases while returning customers exist elsewhere, the contradiction guard fires" do
    label = unique_label
    key = make_product(label)
    period = WeeklyPeriod.new(Date.new(2026, 6, 15))

    # 一位舊客（first_date很久以前），本週第一次買這個測試產品——對這個產品
    # 來說是全新客層，cycle剛建立、還沒有「下一筆同品訂單」，回購比對真的是0，
    # 但快取本身是新鮮的（不是過期問題）。
    email = "returning_new_to_product_#{SecureRandom.hex(4)}@example.com"
    CustomerPurchaseSummary.create!(identity_key: "id_#{email}", email: email,
                                     first_date: period.week_start - 400, purchase_count: 5,
                                     silent_only: false, silent_days_threshold: 45)
    make_order(email: email, product_name: "#{label}3", order_date: period.week_start + 1)

    CrmCustomerProductCycleBuilderService.call(product_key: key)

    result = WeeklyMetricsService.call(week_start: period.week_start)["product_repurchase"]
    product = result["products"].find { |p| p["product_key"] == key }

    assert_not product["cycles_stale"], "cycles were just rebuilt, so this is not a staleness case"
    assert result["contradiction_detected"], "returning_customers>0 with every product's repurchase count at 0 must trip the contradiction guard"
    assert_nil product["repurchased_this_week"], "the guard must null out the number instead of letting a real-looking 0 stand as an economic conclusion"
    assert_includes product["repurchased_this_week_note"], "資料不足"
  end
end
