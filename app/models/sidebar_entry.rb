# path: app/models/sidebar_entry.rb
# frozen_string_literal: true

require "cgi"

class SidebarEntry
  class << self
    include Rails.application.routes.url_helpers

    # 設定快取時間
    CACHE_EXPIRES_IN = 10.minutes

    def all
      [
        {
          # 第一組：核心報表與名單
          group_title: "核心營運 (2026 優先)",
          children: [
            { href: monthly_sales_path, title: "2026 每月銷售趨勢", icon: "fa-calendar-check" },
            { href: products_path, title: "年度 Top 產品排行", icon: "fa-trophy" },
            { href: product_heavy_buyers_path, title: "產品重度購買名單", icon: "fa-user-tag" },
            { href: high_credit_customers_path, title: "高購物金客戶名單", icon: "fa-users" },
            { href: credit_tiers_path, title: "購物金級距 × 產品", icon: "fa-chart-pie" }
          ]
        },
        {
          # 第二組：自動攤平的產品分類
          group_title: "產品分類快速檢視",
          children: flat_product_entries
        },
        {
          # 第三組：基礎資料管理
          group_title: "系統管理",
          children: [
            { href: products_path, title: "所有產品總覽", icon: "fa-box" },
            { href: customers_path, title: "客人資料庫總覽", icon: "fa-address-book" }
          ]
        }
      ]
    end

    private

    def flat_product_entries
      names = fetch_product_names
      # 將「組合」與「單品」分開處理
      combo_names, single_names = names.partition { |n| combo_product_name?(n) }
      
      # 1. 先處理「單品系列」並進行排序
      single_entries = []
      groups = group_products(single_names)
      groups.each do |g|
        base = g[:base_name]
        count = g[:items].size
        single_entries << {
          href: products_path(q: base),
          title: "#{base} 系列 (#{count})",
          icon: "fa-capsules"
        }
      end

      # 排序單品：按數量從多到少
      sorted_entries = single_entries.sort_by { |e| e[:title].match(/\((\d+)\)/)&.captures&.first.to_i || 0 }.reverse

      # 2. 處理「組合系列」並放在最後面
      if combo_names.any?
        sorted_entries << {
          href: products_path(q: "組合"),
          title: "組合系列 (#{combo_names.uniq.size})",
          icon: "fa-layer-group"
        }
      end

      sorted_entries
    end

    # 取得資料庫中不重複的產品名稱
    def fetch_product_names
      Rails.cache.fetch(product_names_cache_key, expires_in: CACHE_EXPIRES_IN) do
        ShoplineOrder
          .where.not(product_name: [nil, ""])
          .distinct
          .pluck(:product_name)
          .map { |s| s.to_s.strip }
          .reject(&:blank?)
      end
    rescue ActiveRecord::NoDatabaseError, ActiveRecord::StatementInvalid
      []
    end

    # 快取 Key，當有新訂單更新時自動失效
    def product_names_cache_key
      v = ShoplineOrder.maximum(:updated_at)&.to_i || 0
      "sidebar:product_names:v5_flat:#{v}"
    end

    # 判斷是否為組合產品
    def combo_product_name?(name)
      s = name.to_s.strip
      return false if s.blank?
      # 包含 +、/、套組、組合，或包含兩組以上數字者判定為組合
      s.match?(/[+＋\/]/) || s.include?("套組") || s.include?("組合") || s.scan(/\d+/).size >= 2
    end

    # 將單品進行歸類（去除結尾數字後的分組）
    def group_products(names)
      map = Hash.new { |h, k| h[k] = [] }

      names.each do |name|
        base, variant = split_base_and_variant(name)
        map[base] << { full_name: name, variant_number: variant }
      end

      map.map { |base, items| { base_name: base, items: items.uniq { |x| x[:full_name] } } }
    end

    # 拆分產品基礎名稱與數字（例如：代謝錠 2 -> [代謝錠, 2]）
    def split_base_and_variant(name)
      s = name.to_s.strip
      m = s.match(/\A(.+?)\s*(\d+)\z/)
      return [s, nil] unless m

      base = m[1].to_s.strip
      num = m[2].to_i
      [base, num]
    end
  end
end