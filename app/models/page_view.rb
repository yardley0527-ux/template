class PageView < ApplicationRecord
  TRACKED_CONTROLLERS = %w[
    welcome customers expiring_members first_purchase high_spender_first_purchase high_value_orders
    inactive_members loyal_customers shopping_credits products product_strategy
    subscription_strategy livestream_analysis livestream_strategy livestreams
    member_contacts
    turmeric_analysis metabolism_analysis glutathione_analysis
    omnipotent_analysis probiotic_analysis omnipotent_restock albums photos
    ads_dashboard duplicate_customers ig_dashboard threads_dashboard
  ].freeze

  # 所有應追蹤的頁面（controller#action），用來計算「從未被造訪」
  ALL_TRACKED_PAGES = {
    "high_value_orders#index"                => "破萬訂單速覽",
    "welcome#index"                         => "首頁 Dashboard",
    "customers#index"                       => "客人資料庫",
    "customers#show"                        => "客人詳細頁",
    "customers#export_inactive"             => "匯出未消費名單",
    "expiring_members#index"                => "即將降級會員",
    "first_purchase#index"                  => "首購總覽",
    "high_spender_first_purchase#index"     => "破萬新客分析",
    "inactive_members#index"                => "近期未消費名單",
    "loyal_customers#index"                 => "忠實客分析",
    "shopping_credits#index"                => "購物金分析",
    "products#index"                        => "年度 Top 產品排行",
    "products#show"                         => "產品詳細頁",
    "product_strategy#index"                => "產品策略報表",
    "subscription_strategy#index"           => "定期購策略分析",
    "member_contacts#index"                 => "會員聯絡名單",
    "member_contacts#export"                => "會員聯絡名單匯出",
    "livestream_analysis#index"             => "直播分析總覽",
    "livestream_strategy#index"             => "直播策略報表",
    "turmeric_analysis#index"               => "直播分析 - 薑黃",
    "turmeric_analysis#export_missing"      => "薑黃未回購匯出",
    "turmeric_analysis#export_event"        => "薑黃本場匯出",
    "metabolism_analysis#index"             => "直播分析 - 代謝錠",
    "metabolism_analysis#export_missing"    => "代謝錠未回購匯出",
    "metabolism_analysis#export_event"      => "代謝錠本場匯出",
    "glutathione_analysis#index"            => "直播分析 - 穀胱甘肽",
    "glutathione_analysis#export_missing"   => "穀胱甘肽未回購匯出",
    "glutathione_analysis#export_event"     => "穀胱甘肽本場匯出",
    "omnipotent_analysis#index"             => "直播分析 - 全能",
    "omnipotent_analysis#export_whitening"  => "全能美白名單匯出",
    "probiotic_analysis#index"              => "直播分析 - 益生菌",
    "probiotic_analysis#export_missing"     => "益生菌未回購匯出",
    "probiotic_analysis#export_event"       => "益生菌本場匯出",
    "omnipotent_restock#index"              => "全能補貨提醒名單",
    "omnipotent_restock#export"             => "補貨名單匯出",
    "albums#index"                          => "相冊列表",
    "albums#show"                           => "相冊詳細頁",
    "ads_dashboard#index"                   => "廣告面板",
    "duplicate_customers#index"             => "重複客人合併",
    "ig_dashboard#index"                    => "IG 面板",
    "livestreams#index"                     => "直播列表",
    "threads_dashboard#index"               => "Threads 面板",
  }.freeze
end
