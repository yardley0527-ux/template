# path: app/models/sidebar_entry.rb
# frozen_string_literal: true

require "cgi"

class SidebarEntry
  class << self
    include Rails.application.routes.url_helpers

    def all
      [
        {
          group_title: "會員管理",
          children: [
            { href: customers_path,          title: "客人資料庫",     icon: "fa-address-book" },
            { href: inactive_members_path,   title: "近期未消費名單", icon: "fa-user-times" },
            { href: member_contacts_path,    title: "會員分群",       icon: "fa-address-card" },
            { href: expiring_members_path,   title: "即將降級會員",   icon: "fa-bell" },
            { href: stats_customers_path,    title: "會員卡別統計",   icon: "fa-chart-bar" },
            { href: shopping_credits_path,   title: "購物金分析",     icon: "fa-credit-card" },
            # { href: duplicate_customers_path, title: "重複客戶偵測",  icon: "fa-user-friends" }
          ]
        },
        {
          group_title: "高消費分析",
          children: [
            { href: daily_orders_path,                title: "每日訂單報表",   icon: "fa-calendar-alt" },
            { href: high_spender_first_purchase_path, title: "破萬新客分析",   icon: "fa-gem" },
            { href: high_value_orders_path,           title: "破萬訂單速覽",   icon: "fa-fire" },
            { href: first_purchase_index_path,        title: "首購總覽",       icon: "fa-shopping-bag" },
            { href: loyal_customers_path,             title: "忠實客分析",     icon: "fa-heart" },
          ]
        },
        {
          group_title: "直播管理",
          children: [
            { href: livestreams_path,           title: "直播歷史",                icon: "fa-film" },
            { href: omnipotent_analysis_path,   title: "直播分析 - 全能",         icon: "fa-video" },
            { href: probiotic_analysis_path,    title: "直播分析 - 益生菌",       icon: "fa-video" },
            { href: livestream_analysis_path,   title: "直播分析 - 品牌之夜總覽", icon: "fa-video" },
            { href: turmeric_analysis_path,     title: "直播分析 - 薑黃",         icon: "fa-video" },
            { href: metabolism_analysis_path,   title: "直播分析 - 代謝錠",       icon: "fa-video" },
            { href: glutathione_analysis_path,  title: "直播分析 - 穀胱甘肽",     icon: "fa-video" },
            { href: omnipotent_restock_path,    title: "全能補貨提醒名單",         icon: "fa-box" },
            { href: livestream_strategy_path,   title: "直播策略報表",             icon: "fa-chart-line" },
          ]
        },
        {
          group_title: "產品 & 策略",
          children: [
            { href: product_strategy_path,      title: "產品策略報表",   icon: "fa-chart-line" },
            { href: products_path,              title: "年度 Top 產品排行", icon: "fa-trophy" },
            { href: subscription_strategy_path, title: "定期購策略分析", icon: "fa-sync-alt" },
          ]
        },
        {
          group_title: "社群 & 廣告",
          children: [
            { href: ads_dashboard_path,       title: "廣告成效面板",   icon: "fa-chart-bar" },
            { href: threads_dashboard_path,   title: "Threads 分析",   icon: "fa-comment-alt" },
            { href: line_broadcast_path,      title: "LINE 推播分析",  icon: "fa-paper-plane" },
            { href: ig_audience_path,         title: "IG 受眾重疊分析", icon: "fa-users" },
            { href: ig_followers_path,        title: "IG 粉絲成長追蹤", icon: "fa-chart-line" },
            { href: "#", title: "業配名單", icon: "fa-star", children: [
                { href: kocs_path,        title: "Hiff 業配名單",   icon: "fa-star" },
                { href: relove_kocs_path, title: "Relove 業配名單", icon: "fa-star" },
              ]
            },
          ]
        },
        {
          group_title: "系統",
          children: [
            { href: monitoring_path, title: "功能使用監控", icon: "fa-chart-line" }
          ]
        },
      ]
    end

  end
end
