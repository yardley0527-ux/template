# path: app/models/sidebar_entry.rb
# frozen_string_literal: true

require "cgi"

class SidebarEntry
  class << self
    include Rails.application.routes.url_helpers

    def all(product_key: nil)
      effective_key = product_key || JourneyProducts::DEFAULT_PRODUCT_KEY
      unread_notifications = Notification.unread.count
      [
        {
          group_title: "營運提醒",
          children: [
            { href: notification_board_path, title: "營運提醒", icon: "fa-bell",
              subtitle: (unread_notifications.positive? ? unread_notifications.to_s : nil),
              subtitle_class: "badge badge-danger" },
            { href: tracked_customers_path, title: "營運追蹤名單", icon: "fa-badge-check" },
            { href: daily_message_lists_path, title: "每日名單回購成效", icon: "fa-comment-check" },
          ]
        },
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
              { href: high_value_order_custom_messages_path, title: "客製化訊息", icon: "fa-comment-alt" },
              { href: high_value_follow_ups_path,            title: "待追蹤名單", icon: "fa-clock" },
              { href: high_value_follow_up_results_path,     title: "追蹤成效",   icon: "fa-clipboard-check" },
            ]},
            { href: product_high_value_customers_path,       title: "產品高破萬次數客人", icon: "fa-badge" },
            { href: spending_rankings_path,                  title: "消費排行榜",         icon: "fa-trophy-alt" },
            { href: stickiness_follow_ups_path,       title: "黏著度分析",     icon: "fa-magnet", children: [
              { href: stickiness_results_path, title: "黏著度成效", icon: "fa-chart-line" },
            ]},
            { href: loyal_customers_path,             title: "產品忠實客",     icon: "fa-heart" },
            { href: black_gold_customers_path,        title: "黑金卡消費備註", icon: "fa-sticky-note" },
          ]
        },
        {
          group_title: "直播管理",
          children: [
            { href: livestream_overview_path,          title: "直播成效總覽", icon: "fa-signal" },
            { href: livestreams_path,                  title: "直播場次",     icon: "fa-film" },
            { href: livestream_product_analysis_path,  title: "產品直播分析", icon: "fa-video" },
            { href: livestream_strategy_path,          title: "直播策略",     icon: "fa-chart-line" },
            { href: livestream_reports_path,           title: "分產品檢討報告", icon: "fa-file-alt" },
          ]
        },
        {
          group_title: "CRM",
          children: [
            { href: crm_home_path(product: effective_key),      title: "CRM 首頁",    icon: "fa-chart-pie" },
            { href: crm_journey_path(product: effective_key),   title: "客戶旅程管理", icon: "fa-map-signs" },
            { href: crm_repurchase_dashboard_path,               title: "回購追蹤 Dashboard", icon: "fa-tasks" },
            { href: livestream_repurchase_candidates_path,       title: "直播回購候選名單", icon: "fa-signal" },
            { href: crm_outreach_tasks_path,                     title: "我的今日任務", icon: "fa-calendar-check" },
            { href: message_lists_path, title: "訊息名單追蹤", icon: "fa-envelope-open" },
            { href: "#", title: "CRM 效益分析", icon: "fa-chart-bar", children: [
              { href: crm_roi_path(product: effective_key),        title: "ROI Dashboard",  icon: "fa-dollar-sign" },
              { href: crm_accuracy_path(product: effective_key),   title: "Journey 預測驗證", icon: "fa-crosshairs" },
              { href: crm_operations_path(product: effective_key), title: "客服操作分析",     icon: "fa-phone-volume" },
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
          group_title: "報告",
          children: [
            { href: livestream_reports_path,    title: "分產品檢討報告", icon: "fa-file-alt" },
            { href: product_reports_path,       title: "產品報告",       icon: "fa-file-alt" },
            { href: new_customer_reports_path,  title: "新客月報",       icon: "fa-user-plus" },
          ]
        },
        {
          group_title: "社群 & 廣告",
          children: [
            { href: ads_dashboard_path,       title: "廣告成效面板",   icon: "fa-chart-bar" },
            { href: live_ad_tests_path,       title: "直播廣告測試",   icon: "fa-bullhorn" },
            { href: line_broadcast_path,      title: "LINE 推播分析",  icon: "fa-paper-plane" },
            { href: ig_audience_path,         title: "IG 受眾重疊分析", icon: "fa-users" },
            { href: ig_followers_path,        title: "IG 粉絲成長追蹤", icon: "fa-chart-line" },
            { href: koc_search_path, title: "業配名單", icon: "fa-star", children: [
                { href: kocs_path,             title: "Hiff 業配名單",     icon: "fa-star" },
                { href: relove_kocs_path,      title: "Relove 業配名單",   icon: "fa-star" },
                { href: body_goals_kocs_path,  title: "Body Goals 業配名單", icon: "fa-star" },
                { href: betterbio_kocs_path,   title: "好好生醫業配名單",   icon: "fa-star" },
                { href: dianbopopo_kocs_path,  title: "Dianbopopo 業配名單", icon: "fa-star" },
                { href: akimia_kocs_path,      title: "微電流面膜業配名單", icon: "fa-star" },
                { href: podcast_contacts_path, title: "Podcast 聯絡名單",  icon: "fa-star" },
                { href: kol_contacts_path,     title: "KOL、藝人聯絡名單", icon: "fa-star" },
              ]
            },
            { href: replied_contacts_path, title: "已回覆待追蹤", icon: "fa-reply" },
          ]
        },
        {
          group_title: "業配評估",
          group_icon: "fa-handshake",
          children: [
            { href: kol_candidates_path, title: "業配報價評估", icon: "fa-user-tie" },
          ]
        },
        {
          group_title: "Omnichat 加 tag 名單",
          children: [
            { href: tag_extractions_path, title: "Omnichat 加 tag 名單", icon: "fa-tag" },
          ]
        },
        {
          group_title: "客服支援",
          children: [
            { href: faqs_path, title: "常見問題", icon: "fa-question-circle" },
            { href: manychat_checks_path, title: "ManyChat 每日確認", icon: "fa-check-square" },
          ]
        },
        {
          group_title: "工具 & 系統",
          children: [
            { href: monitoring_path,                     title: "功能使用監控",     icon: "fa-chart-line" },
            { href: canceled_order_candidates_path,       title: "已取消訂單候選名單", icon: "fa-ban" },
            { href: users_path,                           title: "使用者管理",       icon: "fa-users" },
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
          # A "#" container (e.g. CRM 效益分析) has no controller of its own, so
          # it must only show up when at least one child is allowed — unlike a
          # real page (e.g. 客人資料庫，或有自己頁面的 業配名單) whose own
          # controller permission should be enough on its own, even with no
          # permitted children.
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
