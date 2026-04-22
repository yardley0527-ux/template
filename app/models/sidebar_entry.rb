# path: app/models/sidebar_entry.rb
# frozen_string_literal: true

require "cgi"

class SidebarEntry
  class << self
    include Rails.application.routes.url_helpers

    CACHE_EXPIRES_IN = 10.minutes

    def all
      [
        {
          group_title: "系統管理",
          children: [
            { href: customers_path,       title: "客人資料庫總覽", icon: "fa-address-book" },
            { href: expiring_members_path, title: "即將降級會員",   icon: "fa-bell" },
            { href: stats_customers_path,  title: "會員卡別統計",   icon: "fa-chart-bar" }
          ]
        },
        {
          group_title: "忠實客管理",
          children: [
            { href: loyal_customers_path, title: "忠實客分析", icon: "fa-heart" }
          ]
        },
        {
          group_title: "破萬管理",
          children: [
            { href: high_spender_first_purchase_path, title: "破萬新客、產品分析", icon: "fa-gem" }
          ]
        },
        {
          group_title: "首購管理",
          children: [
            { href: first_purchase_index_path,title: "首購總覽",   icon: "fa-shopping-bag" },
            { href: first_purchase_index_path(silent_only: 1), title: "沉默客名單", icon: "fa-user-times" }
          ]
        },
        {
          group_title: "策略管理",
          children: [
            { href: product_strategy_path,title: "產品策略報表",   icon: "fa-chart-line" }
          ]
        },
        {
          group_title: "直播管理",
          children: [
            { href: livestream_analysis_path, title: "直播分析 - 薑黃品牌之夜",   icon: "fa-video" },
            { href: metabolism_analysis_path, title: "直播分析 - 代謝錠品牌之夜", icon: "fa-video" }
          ]
        },
        {
          group_title: "產品分類快速檢視",
          children: [
            { href: products_path, title: "年度 Top 產品排行", icon: "fa-trophy" },
            *flat_product_entries
          ]
        }
      ]
    end

    private

    def flat_product_entries
      names = fetch_product_names
      combo_names, single_names = names.partition { |n| combo_product_name?(n) }

      single_entries = group_products(single_names).map do |g|
        {
          href: products_path(q: g[:base_name]),
          title: "#{g[:base_name]} 系列 (#{g[:items].size})",
          icon: "fa-capsules"
        }
      end

      sorted_entries = single_entries.sort_by { |e| e[:title].match(/\((\d+)\)/)&.captures&.first.to_i || 0 }.reverse

      if combo_names.any?
        sorted_entries << {
          href: products_path(combo: "1"),
          title: "組合系列 (#{combo_names.size})",
          icon: "fa-layer-group"
        }
      end

      sorted_entries
    end

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

    def product_names_cache_key
      v = ShoplineOrder.maximum(:updated_at)&.to_i || 0
      "sidebar:product_names:v5_flat:#{v}"
    end

    def combo_product_name?(name)
      name.match?(/\D+\d+\D+\d+/) || name.match?(/[+＋\/]/) || name.include?("套組")
    end

    def group_products(names)
      map = Hash.new { |h, k| h[k] = [] }

      names.each do |name|
        base, variant = split_base_and_variant(name)
        map[base] << { full_name: name, variant_number: variant }
      end

      map.map { |base, items| { base_name: base, items: items } }
    end

    def split_base_and_variant(name)
      m = name.match(/\A(.+?)\s*(\d+)\z/)
      return [name, nil] unless m

      [m[1].strip, m[2].to_i]
    end
  end
end