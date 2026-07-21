# frozen_string_literal: true

require "test_helper"

class ProductLivestreamAnalyticsTest < ActiveSupport::TestCase
  TAIPEI = ActiveSupport::TimeZone["Asia/Taipei"]

  def taipei(y, m, d, h = 10) = TAIPEI.local(y, m, d, h)

  def crm_product!(key, label = key)
    CrmProduct.find_or_create_by!(key: key) { |c| c.label = label; c.status = "confirmed"; c.include_in_analysis = true }
  end

  def livestream!(date, keys:, window_days: 3)
    Livestream.create!(date: date, product_keys: keys, window_days: window_days)
  end

  def order!(order_number:, email:, order_date:, total_amount:, product_name: "薑黃1", membership_level: nil)
    customer = if email && membership_level
                 ShoplineCustomer.find_or_create_by!(email: email) { |c| c.membership_level = membership_level }
               end
    ShoplineOrder.create!(order_number: order_number, email: email, order_date: order_date,
                          total_amount: total_amount, product_name: product_name, shopline_customer_id: customer&.id)
  end

  def map!(raw_name, crm_product)
    ProductNameMapping.find_or_create_by!(raw_name: raw_name, source: "shopline_order") do |m|
      m.mapping_status = "confirmed_alias"
      m.crm_product_id = crm_product.id
    end
  end

  setup do
    @turmeric = crm_product!("turmeric", "薑黃")
    map!("薑黃1", @turmeric)
  end

  # ── 場次來源：product_keys 而非 ALL_EVENTS/note ─────────────────────────

  test "events only includes livestreams whose product_keys contains this product" do
    a = livestream!(Date.new(1990, 1, 1), keys: ["turmeric"])
    livestream!(Date.new(1990, 1, 8), keys: ["omnipotent"])

    analytics = ProductLivestreamAnalytics.new("turmeric")
    assert_equal [a.id], analytics.events.map(&:id)
  end

  test "past_events excludes future-dated livestreams" do
    livestream!(Date.current + 5, keys: ["turmeric"])
    past = livestream!(Date.current - 5, keys: ["turmeric"])

    analytics = ProductLivestreamAnalytics.new("turmeric")
    assert_equal [past.id], analytics.past_events.map(&:id)
  end

  # ── 跨場趨勢與回流率 ─────────────────────────────────────────────────────

  test "cross_event_stats computes buyers/revenue/aov and return_rate against the previous event" do
    livestream!(Date.new(1991, 1, 1), keys: ["turmeric"])
    livestream!(Date.new(1991, 1, 15), keys: ["turmeric"])
    order!(order_number: "O1", email: "a@x.com", order_date: taipei(1991, 1, 1), total_amount: 1000)
    order!(order_number: "O2", email: "b@x.com", order_date: taipei(1991, 1, 1), total_amount: 500)
    order!(order_number: "O3", email: "a@x.com", order_date: taipei(1991, 1, 15), total_amount: 800) # 回流

    stats = ProductLivestreamAnalytics.new("turmeric").cross_event_stats
    assert_equal 2, stats.size
    assert_nil stats.first[:return_rate]
    assert_equal 2, stats.first[:buyers]
    assert_equal 1, stats.last[:buyers]
    assert_equal 50.0, stats.last[:return_rate] # 1/2
  end

  # ── 鐵粉／流失黑金卡 ─────────────────────────────────────────────────────

  test "iron_fans requires at least 2 events and returns the email intersection" do
    livestream!(Date.new(1992, 1, 1), keys: ["turmeric"])
    order!(order_number: "S1", email: "fan@x.com", order_date: taipei(1992, 1, 1), total_amount: 100, membership_level: "黑卡")
    assert_empty ProductLivestreamAnalytics.new("turmeric").iron_fans

    livestream!(Date.new(1992, 1, 15), keys: ["turmeric"])
    order!(order_number: "S2", email: "fan@x.com", order_date: taipei(1992, 1, 15), total_amount: 100)
    order!(order_number: "S3", email: "onceonly@x.com", order_date: taipei(1992, 1, 15), total_amount: 100, membership_level: "金卡")

    fans = ProductLivestreamAnalytics.new("turmeric").iron_fans
    assert_equal ["fan@x.com"], fans.map { |f| f[:customer].email }
    assert_equal 2, fans.first[:attended_count]
  end

  test "high_risk_lost only includes 黑卡/金卡 customers present earlier but absent from the latest event" do
    livestream!(Date.new(1993, 1, 1), keys: ["turmeric"])
    order!(order_number: "L1", email: "black@x.com", order_date: taipei(1993, 1, 1), total_amount: 100, membership_level: "黑卡")
    order!(order_number: "L2", email: "white@x.com", order_date: taipei(1993, 1, 1), total_amount: 100, membership_level: "白卡")

    livestream!(Date.new(1993, 1, 15), keys: ["turmeric"])
    order!(order_number: "L3", email: "someone_else@x.com", order_date: taipei(1993, 1, 15), total_amount: 100)

    lost = ProductLivestreamAnalytics.new("turmeric").high_risk_lost
    assert_equal ["black@x.com"], lost.map { |r| r[:customer].email }, "白卡不列入流失黑金卡名單"
  end

  # ── 未回購／即將回購 ─────────────────────────────────────────────────────

  test "missing_customers excludes buyers who already appear in the latest event" do
    # 薑黃1 = 1 瓶 = 30 天供給量；買在 60 天前 → 預期回購日 30 天前 → 逾期 30 天，
    # 落在「逾期 1~90 天」「近 180 天內活躍」兩個條件之內，才會被判定為未回購。
    first_date = Date.current - 60
    livestream!(first_date, keys: ["turmeric"])
    order!(order_number: "M1", email: "gone@x.com", order_date: taipei(first_date.year, first_date.month, first_date.day),
           total_amount: 100, membership_level: "金卡")
    livestream!(Date.current - 20, keys: ["turmeric"])
    # gone@x.com 沒有出現在最新場

    rows = ProductLivestreamAnalytics.new("turmeric").missing_customers
    assert_equal ["gone@x.com"], rows.map { |r| r[:customer].email }
  end

  # ── 產品辨識覆蓋率 ───────────────────────────────────────────────────────

  test "recognition_coverage returns nil when there are no past events" do
    assert_nil ProductLivestreamAnalytics.new("turmeric").recognition_coverage
  end

  test "recognition_coverage is the pct of orders in-window whose product_name has a confirmed alias" do
    livestream!(Date.new(1994, 1, 1), keys: ["turmeric"], window_days: 0)
    order!(order_number: "R1", email: "a@x.com", order_date: taipei(1994, 1, 1), total_amount: 100, product_name: "薑黃1") # mapped
    order!(order_number: "R2", email: "b@x.com", order_date: taipei(1994, 1, 1), total_amount: 100, product_name: "未知品名XYZ") # not mapped

    coverage = ProductLivestreamAnalytics.new("turmeric").recognition_coverage
    assert_equal 50.0, coverage
  end

  # ── 組合包拆解警語 ───────────────────────────────────────────────────────

  test "bundle_components_decomposed? reflects whether product_mapping_components has any rows" do
    assert_not ProductLivestreamAnalytics.new("turmeric").bundle_components_decomposed?

    mapping = ProductNameMapping.create!(raw_name: "薑黃1全能1", source: "shopline_order", mapping_status: "confirmed_alias", crm_product_id: @turmeric.id)
    ProductMappingComponent.create!(product_name_mapping: mapping, crm_product: @turmeric, paid_quantity: 1)

    assert ProductLivestreamAnalytics.new("turmeric").bundle_components_decomposed?
  end

  # ── 交叉銷售（參數化）─────────────────────────────────────────────────

  test "cross_sell finds lapsed black/gold buyers of the target product within source event windows" do
    whitening = crm_product!("whitening", "美白")
    map!("美白1", whitening)
    omni = crm_product!("omnipotent", "全能")
    map!("全能1", omni)

    ls = livestream!(Date.new(1995, 1, 1), keys: ["omnipotent"], window_days: 3)
    order!(order_number: "C1", email: "cross@x.com", order_date: taipei(1995, 1, 1), total_amount: 500, product_name: "全能1", membership_level: "黑卡")
    order!(order_number: "C2", email: "cross@x.com", order_date: taipei(1995, 1, 2), total_amount: 300, product_name: "美白1")
    # 之後沒有再買美白 → 應出現在名單

    buyers = ProductLivestreamAnalytics.new("omnipotent").cross_sell(target_key: "whitening")
    assert_equal ["cross@x.com"], buyers.map { |r| r[:customer].email }
    assert_equal 1, buyers.first[:source_event_count]
  end

  test "cross_sell excludes buyers who rebought the target product after the window" do
    whitening = crm_product!("whitening", "美白")
    map!("美白1", whitening)
    omni = crm_product!("omnipotent", "全能")
    map!("全能1", omni)

    livestream!(Date.new(1996, 1, 1), keys: ["omnipotent"], window_days: 3)
    order!(order_number: "D1", email: "rebought@x.com", order_date: taipei(1996, 1, 1), total_amount: 500, product_name: "全能1", membership_level: "黑卡")
    order!(order_number: "D2", email: "rebought@x.com", order_date: taipei(1996, 1, 2), total_amount: 300, product_name: "美白1")
    order!(order_number: "D3", email: "rebought@x.com", order_date: taipei(1996, 2, 1), total_amount: 300, product_name: "美白1") # 窗後再買

    buyers = ProductLivestreamAnalytics.new("omnipotent").cross_sell(target_key: "whitening")
    assert_empty buyers
  end
end
