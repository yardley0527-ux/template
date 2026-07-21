# path: app/models/sidebar_entry.rb
# frozen_string_literal: true

require "cgi"

class SidebarEntry
  class << self
    include Rails.application.routes.url_helpers

    def all(product_key: nil)
      effective_key = product_key || JourneyProducts::DEFAULT_PRODUCT_KEY
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
            { href: ig_email_lookup_path,    title: "IG 查 Email",    icon: "fa-at" },
            # { href: duplicate_customers_path, title: "重複客戶偵測",  icon: "fa-user-friends" }
          ]
        },
        {
          group_title: "高消費分析",
          children: [
            { href: daily_dashboard_path,             title: "每日營收儀表板", icon: "fa-tachometer-alt" },
            { href: daily_orders_path,               title: "每日訂單明細",   icon: "fa-list-alt", children: [
              { href: message_templates_path, title: "訊息公版", icon: "fa-copy" },
            ]},
            { href: high_spender_first_purchase_path, title: "破萬新客分析",   icon: "fa-gem" },
            { href: high_value_orders_path,           title: "破8000訂單速覽", icon: "fa-fire", children: [
              { href: high_value_order_custom_messages_path, title: "客製化訊息", icon: "fa-comment-dots" },
              { href: high_value_follow_ups_path,            title: "待追蹤名單", icon: "fa-user-clock" },
              { href: high_value_follow_up_results_path,     title: "追蹤成效",   icon: "fa-clipboard-check" },
            ]},
            { href: product_high_value_customers_path,       title: "產品高破萬次數客人", icon: "fa-medal" },
            { href: spending_rankings_path,                  title: "消費排行榜",         icon: "fa-crown" },
            { href: stickiness_follow_ups_path,       title: "黏著度分析",     icon: "fa-magnet", children: [
              { href: stickiness_results_path, title: "黏著度成效", icon: "fa-chart-line" },
            ]},
            { href: loyal_customers_path,             title: "產品忠實客",     icon: "fa-heart" },
          ]
        },
        {
          group_title: "直播管理",
          children: [
            { href: livestream_overview_path,          title: "直播成效總覽", icon: "fa-broadcast-tower" },
            { href: livestreams_path,                  title: "直播場次",     icon: "fa-film" },
            { href: livestream_product_analysis_path,  title: "產品直播分析", icon: "fa-video" },
            { href: livestream_strategy_path,          title: "直播策略",     icon: "fa-chart-line" },
          ]
        },
        {
          group_title: "CRM",
          children: [
            { href: crm_home_path(product: effective_key),      title: "CRM 首頁",    icon: "fa-chart-pie" },
            { href: crm_journey_path(product: effective_key),   title: "客戶旅程管理", icon: "fa-route" },
            { href: crm_broadcast_path(product: effective_key), title: "直播邀請管理", icon: "fa-broadcast-tower" },
            { href: message_lists_path, title: "訊息名單追蹤", icon: "fa-envelope-open-text" },
            { href: "#", title: "CRM 效益分析", icon: "fa-chart-bar", children: [
              { href: crm_roi_path(product: effective_key),        title: "ROI Dashboard",  icon: "fa-dollar-sign" },
              { href: crm_accuracy_path(product: effective_key),   title: "Journey 預測驗證", icon: "fa-crosshairs" },
              { href: crm_operations_path(product: effective_key), title: "客服操作分析",     icon: "fa-headset" },
            ]},
          ]
        },
        {
          group_title: "產品 & 策略",
          children: [
            { href: product_strategy_path,      title: "產品策略報表",   icon: "fa-chart-line" },
            { href: products_path,              title: "年度 Top 產品排行", icon: "fa-trophy" },
            { href: product_inventory_path,     title: "產品庫存",       icon: "fa-boxes" },
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
          group_title: "工具 & 系統",
          children: [
            { href: monitoring_path,        title: "功能使用監控", icon: "fa-chart-line" },
            { href: users_path,             title: "使用者管理",   icon: "fa-users-cog" },
          ]
        },
      ]
    end

    # Same shape as .all, but with pages the user's role can't access removed.
    def visible_for(user, product_key: nil)
      entries = all(product_key: product_key)
      return entries if user&.admin?

      allowed = user&.role&.page_permissions&.pluck(:controller_name) || []
      entries.filter_map do |group|
        children = filter_children(group[:children], allowed)
        next if children.empty?

        group.merge(children: children)
      end
    end

    private

    def filter_children(children, allowed)
      children.filter_map do |child|
        controller = PageRegistry.controller_for(child[:href])

        if child[:children].present?
          # A "#" container (e.g. CRM 效益分析, 業配名單) has no controller of its
          # own, so it must only show up when at least one child is allowed —
          # unlike a real page (e.g. 客人資料庫) whose own controller permission
          # should be enough on its own, even with no permitted children.
          own_allowed = controller.present? && allowed.include?(controller)
          sub = filter_children(child[:children], allowed)
          next if sub.empty? && !own_allowed

          child.merge(children: sub)
        else
          child if controller.nil? || allowed.include?(controller)
        end
      end
    end
  end
end
