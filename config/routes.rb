Rails.application.routes.draw do
  devise_for :users, skip: [:registrations], controllers: { sessions: 'users/sessions' }

  root 'welcome#index'

  resources :message_templates, only: [:index, :create, :update, :destroy] do
    collection { patch :reorder }
  end
  resources :message_template_blocks, only: [:create, :update, :destroy] do
    collection { patch :reorder }
  end
  resources :message_template_images, only: [:create, :destroy]

  resources :faq_categories, only: [:create, :update, :destroy] do
    collection { patch :reorder }
  end
  resources :faqs, only: [:index, :create, :update, :destroy] do
    collection { patch :reorder }
  end
  resources :faq_images, only: [:create, :destroy]

  # 月曆已搬進首頁；舊網址導回首頁（保留 month 參數）
  get "calendar_events", to: redirect(path: "/")
  resources :calendar_events, only: [:new, :create, :edit, :update, :destroy] do
    collection { post :sync_departments }
  end
  resources :bulletin_notes, only: [:create, :destroy] do
    member { patch :toggle }
  end
  # 便條只有 POST；瀏覽器重整/歷史記錄會用 GET 打到這裡，導回首頁而不是 500
  get "/bulletin_notes", to: redirect("/")
  get "/boards/:department", to: "bulletin_notes#board", as: :department_board,
                             constraints: { department: /[^\/]+/ }
  post "/boards/:department/sections", to: "bulletin_notes#create_section", as: :department_board_sections,
                                       constraints: { department: /[^\/]+/ }
  delete "/board_sections/:id", to: "bulletin_notes#destroy_section", as: :board_section

  resources :livestreams, only: [:index, :show, :new, :create, :edit, :update, :destroy] do
    resources :livestream_images, only: [:create, :destroy]
    resources :livestream_products, only: [:create, :update, :destroy]
    resources :livestream_gifts, only: [:create, :update, :destroy]
    member do
      post :complete_review
      post :assign_owner
    end
  end
  get '/livestream_overview', to: 'livestream_overview#index', as: :livestream_overview
  get '/livestream_reports', to: 'livestream_reports#index', as: :livestream_reports
  get '/new_customer_reports', to: 'new_customer_reports#index', as: :new_customer_reports
  get '/livestream_product_analysis',               to: 'livestream_product_analysis#index',         as: :livestream_product_analysis
  get '/livestream_product_analysis/export_missing', to: 'livestream_product_analysis#export_missing', as: :export_missing_livestream_product_analysis
  get '/livestream_product_analysis/export_event',   to: 'livestream_product_analysis#export_event',   as: :export_event_livestream_product_analysis
  get '/livestream_product_analysis/export_action',  to: 'livestream_product_analysis#export_action',  as: :export_action_livestream_product_analysis
  get '/monitoring',          to: 'monitoring#index',           as: :monitoring
  resources :users, only: [:index, :new, :create, :update]
  get  '/high_value_orders',        to: 'high_value_orders#index',    as: :high_value_orders
  get  '/high_value_orders/custom_messages', to: 'high_value_order_custom_messages#index', as: :high_value_order_custom_messages
  get  '/high_value_orders/follow_ups', to: 'high_value_follow_ups#index', as: :high_value_follow_ups
  get  '/high_value_orders/follow_up_results', to: 'high_value_follow_up_results#index', as: :high_value_follow_up_results
  get  '/stickiness',             to: 'stickiness_follow_ups#index',       as: :stickiness_follow_ups
  get  '/stickiness/results',     to: 'stickiness_results#index',          as: :stickiness_results
  post '/stickiness/upsert_note', to: 'stickiness_follow_ups#upsert_note', as: :upsert_stickiness_note
  post '/stickiness/toggle_maintained', to: 'stickiness_follow_ups#toggle_maintained', as: :toggle_stickiness_maintained
  get  '/black_gold_customers',             to: 'black_gold_customers#index',       as: :black_gold_customers
  post '/black_gold_customers/upsert_note', to: 'black_gold_customers#upsert_note', as: :upsert_black_gold_note
  post '/black_gold_customers/analyze',     to: 'black_gold_customers#analyze',     as: :analyze_black_gold_customer
  post '/black_gold_customers/toggle_followed_up', to: 'black_gold_customers#toggle_followed_up', as: :toggle_black_gold_followed_up
  get  '/daily_dashboard',           to: 'daily_dashboard#index',      as: :daily_dashboard
  get  '/daily_orders',             to: 'daily_orders#index',         as: :daily_orders
  get  '/daily_orders/export',      to: 'daily_orders#export',        as: :export_daily_orders
  post '/daily_orders/toggle_customer_flag', to: 'daily_orders#toggle_customer_flag', as: :toggle_daily_orders_customer_flag
  post '/daily_orders/update_customer_type', to: 'daily_orders#update_customer_type', as: :update_daily_orders_customer_type
  post '/order_gift_records/upsert', to: 'order_gift_records#upsert',  as: :upsert_order_gift_record
  get  '/member_contacts',                to: 'member_contacts#index',          as: :member_contacts
  get  '/member_contacts/export',        to: 'member_contacts#export',         as: :member_contacts_export
  post '/member_contacts/refresh_line',  to: 'member_contacts#refresh_line',   as: :member_contacts_refresh_line
  post '/member_contacts/update_sl',     to: 'member_contacts#update_sl',      as: :member_contacts_update_sl
  get  '/ig_dashboard',             to: 'ig_dashboard#index',         as: :ig_dashboard
  get  '/ig_followers',             to: 'ig_followers#index',         as: :ig_followers
  get  '/ads_dashboard',            to: 'ads_dashboard#index',        as: :ads_dashboard
  resources :kocs, only: [:index, :create, :update, :destroy] do
    patch :message_template, on: :collection, action: :update_message_template
  end
  resources :relove_kocs, only: [:index, :create, :update, :destroy]
  resources :podcast_contacts, only: [:index, :create, :update, :destroy] do
    patch :message_template, on: :collection, action: :update_message_template
  end
  resources :kol_contacts, only: [:index, :create, :update, :destroy] do
    patch :message_template, on: :collection, action: :update_message_template
  end
  get  '/line_broadcast',           to: 'line_broadcast#index',       as: :line_broadcast
  resources :line_broadcast_highlights, only: [:create, :destroy]
  get  '/ig_audience',              to: 'ig_audience#index',          as: :ig_audience
  get  '/ig_audience/detail',       to: 'ig_audience#detail',         as: :ig_audience_detail
  get  '/ig_audience/export',       to: 'ig_audience#export',         as: :ig_audience_export
  get  '/ig_audience/export_no_line', to: 'ig_audience#export_no_line', as: :ig_audience_export_no_line
  get  '/ig_audience/export_with_line', to: 'ig_audience#export_with_line', as: :ig_audience_export_with_line
  get  '/ig_audience/export_high_value_silent', to: 'ig_audience#export_high_value_silent', as: :ig_audience_export_high_value_silent
  post '/ig_dashboard/refresh',     to: 'ig_dashboard#refresh',       as: :ig_dashboard_refresh
  get "/api/birthday_customers", to: "welcome#birthday_customers"
  # 方案 B PR4：舊直播分析頁併入共用產品分析頁／策略頁「出席與回流」頁籤。
  # 302（非 301）轉址，保留舊網址相容性；舊 controller/view 原封不動保留，
  # 只有這個 index route 被取代（export_* 子路由仍指向舊 controller，未轉址）。
  get '/livestream_analysis', to: redirect(path: "/livestream_strategy/attendance", status: 302), as: :livestream_analysis
  get '/turmeric_analysis',   to: redirect(path: "/livestream_product_analysis?product=turmeric", status: 302), as: :turmeric_analysis
  get '/turmeric_analysis/export_missing', to: 'turmeric_analysis#export_missing',  as: :turmeric_export_missing
  get '/turmeric_analysis/export_event',   to: 'turmeric_analysis#export_event',    as: :turmeric_export_event
  get '/metabolism_analysis', to: redirect(path: "/livestream_product_analysis?product=metabolism", status: 302), as: :metabolism_analysis
  get '/metabolism_analysis/export_missing', to: 'metabolism_analysis#export_missing', as: :metabolism_export_missing
  get '/metabolism_analysis/export_event',   to: 'metabolism_analysis#export_event',   as: :metabolism_export_event
  get '/glutathione_analysis', to: redirect(path: "/livestream_product_analysis?product=glutathione", status: 302), as: :glutathione_analysis
  get '/glutathione_analysis/export_missing', to: 'glutathione_analysis#export_missing',  as: :glutathione_export_missing
  get '/glutathione_analysis/export_event',   to: 'glutathione_analysis#export_event',    as: :glutathione_export_event
  get '/probiotic_analysis', to: redirect(path: "/livestream_product_analysis?product=probiotic", status: 302), as: :probiotic_analysis
  get '/probiotic_analysis/export_missing', to: 'probiotic_analysis#export_missing',  as: :probiotic_export_missing
  get '/probiotic_analysis/export_event',   to: 'probiotic_analysis#export_event',    as: :probiotic_export_event
  get '/probiotic_analysis/export_action',  to: 'probiotic_analysis#export_action',   as: :probiotic_export_action
  get '/omnipotent_analysis', to: redirect(path: "/livestream_product_analysis?product=omnipotent", status: 302), as: :omnipotent_analysis
  get '/omnipotent_analysis/export_missing',    to: 'omnipotent_analysis#export_missing',    as: :omnipotent_export_missing
  get '/omnipotent_analysis/export_event',     to: 'omnipotent_analysis#export_event',      as: :omnipotent_export_event
  get '/omnipotent_analysis/export_whitening', to: 'omnipotent_analysis#export_whitening',  as: :omnipotent_export_whitening
  # ── CRM 功能模組（通用 URL，不綁定產品名稱）────────────────────────
  get   '/crm',                        to: 'omnipotent_restock#boss_dashboard',        as: :crm_home
  get   '/crm/journey',                to: 'omnipotent_restock#index',                 as: :crm_journey
  get   '/crm/analytics/roi',          to: 'omnipotent_restock#roi_dashboard',         as: :crm_roi
  get   '/crm/analytics/accuracy',     to: 'omnipotent_restock#journey_accuracy',      as: :crm_accuracy
  get   '/crm/analytics/operations',   to: 'omnipotent_restock#crm_analysis',          as: :crm_operations
  # 直播來源分析已併入直播策略報表的「來源分析」頁籤，舊網址保留轉跳
  get   '/crm/analytics/broadcasts',   to: redirect { |_params, req|
    ["/livestream_strategy/sources", req.query_string.presence].compact.join("?")
  }, as: :crm_broadcasts
  get   '/crm/customer/:id',           to: 'omnipotent_restock#customer_journey',      as: :crm_customer_journey
  get   '/crm/export',                 to: 'omnipotent_restock#export',                as: :crm_export
  get   '/crm/export_daily',           to: 'omnipotent_restock#export_daily',          as: :crm_export_daily
  get   '/crm/export_at_risk',         to: 'omnipotent_restock#export_at_risk',        as: :crm_export_at_risk
  get   '/crm/export_loyal',           to: 'omnipotent_restock#export_loyal',          as: :crm_export_loyal
  patch '/crm/update_status',          to: 'omnipotent_restock#update_status',         as: :crm_update_status

  # ── 回購追蹤 Dashboard（Phase 2）────────────────────────────────────
  get   '/crm/repurchase_dashboard',        to: 'crm_repurchase_follow_ups#index',  as: :crm_repurchase_dashboard
  patch '/crm/repurchase_dashboard/:id',    to: 'crm_repurchase_follow_ups#update', as: :crm_repurchase_follow_up

  # ── 直播回購候選名單（Phase 3）──────────────────────────────────────
  get   '/crm/livestreams/candidates',                            to: 'livestream_repurchase_candidates#index',  as: :livestream_repurchase_candidates
  patch '/crm/livestreams/:livestream_id/candidates/:cycle_id',   to: 'livestream_repurchase_candidates#update', as: :livestream_repurchase_candidate

  # ── 客服排程（Phase 4）──────────────────────────────────────────────
  get   '/crm/livestreams/:livestream_id/schedule/new',      to: 'crm_livestream_schedules#new',     as: :new_crm_livestream_schedule
  post  '/crm/livestreams/:livestream_id/schedule/preview',  to: 'crm_livestream_schedules#preview', as: :preview_crm_livestream_schedule
  post  '/crm/livestreams/:livestream_id/schedule',          to: 'crm_livestream_schedules#create',  as: :crm_livestream_schedule

  get   '/crm/outreach_tasks',                to: 'crm_outreach_tasks#index',      as: :crm_outreach_tasks
  patch '/crm/outreach_tasks/:id',            to: 'crm_outreach_tasks#update',     as: :crm_outreach_task
  patch '/crm/outreach_tasks/:id/reschedule', to: 'crm_outreach_tasks#reschedule', as: :reschedule_crm_outreach_task

  # ── 舊路由保留（向後相容）────────────────────────────────────────────
  get   '/omnipotent_restock',                         to: 'omnipotent_restock#index',                as: :omnipotent_restock
  get   '/omnipotent_restock/export',                  to: 'omnipotent_restock#export',               as: :omnipotent_restock_export
  get   '/omnipotent_restock/export_at_risk',          to: 'omnipotent_restock#export_at_risk',       as: :omnipotent_restock_export_at_risk
  get   '/omnipotent_restock/export_loyal',            to: 'omnipotent_restock#export_loyal',         as: :omnipotent_restock_export_loyal
  patch '/omnipotent_restock/update_status',           to: 'omnipotent_restock#update_status',        as: :omnipotent_restock_update_status
  get   '/omnipotent_restock/boss_dashboard',          to: 'omnipotent_restock#boss_dashboard',       as: :omnipotent_restock_boss_dashboard
  get   '/omnipotent_restock/roi_dashboard',           to: 'omnipotent_restock#roi_dashboard',        as: :omnipotent_restock_roi_dashboard
  get   '/omnipotent_restock/journey_accuracy',        to: 'omnipotent_restock#journey_accuracy',     as: :omnipotent_restock_journey_accuracy
  get   '/omnipotent_restock/crm_analysis',            to: 'omnipotent_restock#crm_analysis',         as: :omnipotent_restock_crm_analysis
  get   '/omnipotent_restock/broadcast_performance',   to: 'omnipotent_restock#broadcast_performance', as: :omnipotent_restock_broadcast_performance
  get   '/omnipotent_restock/customer_journey/:id',    to: 'omnipotent_restock#customer_journey',     as: :omnipotent_restock_customer_journey
  get 'customers/export_inactive',         to: 'customers#export_inactive',         as: :export_inactive_customers
  get 'customers/export_credits_expiring', to: 'customers#export_credits_expiring', as: :export_credits_expiring_customers

  resources :expiring_members, only: [:index] do
    post :confirm_renewal, on: :member
  end  
  get '/loyal_customers',            to: 'loyal_customers#index',      as: :loyal_customers
  get '/product_high_value_customers', to: 'product_high_value_customers#index', as: :product_high_value_customers
  get '/spending_rankings', to: 'spending_rankings#index', as: :spending_rankings
  get '/metabolism_qingxian_customers',        to: 'metabolism_qingxian_customers#index',  as: :metabolism_qingxian_customers
  get '/metabolism_qingxian_customers/export', to: 'metabolism_qingxian_customers#export', as: :export_metabolism_qingxian_customers
  get '/canceled_order_candidates',        to: 'canceled_order_candidates#index', as: :canceled_order_candidates
  post '/canceled_order_candidates/purge', to: 'canceled_order_candidates#purge',  as: :purge_canceled_order_candidates
  get '/tag_extractions',            to: 'tag_extractions#index',  as: :tag_extractions
  post '/tag_extractions',           to: 'tag_extractions#create'
  get '/tag_extractions/:id/export', to: 'tag_extractions#export', as: :export_tag_extraction
  post '/tag_extraction_runs/update_field', to: 'tag_extractions#update_field', as: :update_tag_extraction_run_field
  get '/message_lists',            to: 'message_lists#index',  as: :message_lists
  get '/message_lists/:id',        to: 'message_lists#show',   as: :message_list
  patch '/message_lists/:id',      to: 'message_lists#update'
  get '/message_lists/:id/export', to: 'message_lists#export', as: :export_message_list
  get '/inactive_members',           to: 'inactive_members#index',     as: :inactive_members
  get  '/duplicate_customers',         to: 'duplicate_customers#index', as: :duplicate_customers
  post '/duplicate_customers/merge',   to: 'duplicate_customers#merge', as: :merge_duplicate_customers
  get '/product_strategy',      to: 'product_strategy#index',      as: :product_strategy
  get '/product_inventory',     to: 'product_inventory#index',     as: :product_inventory
  get '/product_reports',       to: 'product_reports#index',       as: :product_reports
  get '/subscription_strategy', to: 'subscription_strategy#index', as: :subscription_strategy
  get   '/high_spender_first_purchase',             to: 'high_spender_first_purchase#index',       as: :high_spender_first_purchase
  post  '/high_spender_first_purchase/snapshot',    to: 'high_spender_first_purchase#snapshot',    as: :high_spender_first_purchase_snapshot
  patch '/high_spender_first_purchase/update_field', to: 'high_spender_first_purchase#update_field', as: :high_spender_first_purchase_update_field
  post '/high_spender_follow_ups',              to: 'high_spender_follow_ups#create',        as: :high_spender_follow_ups
  get '/shopping_credits',    to: 'shopping_credits#index',    as: :shopping_credits
  get '/ig_email_lookup',     to: 'ig_email_lookup#index',     as: :ig_email_lookup
  get '/livestream_strategy', to: 'livestream_strategy#index', as: :livestream_strategy
  get '/livestream_strategy/attendance', to: 'livestream_strategy#attendance', as: :livestream_strategy_attendance
  get '/livestream_strategy/sources', to: 'livestream_strategy#sources', as: :livestream_strategy_sources
  get '/livestream_strategy/windows', to: 'livestream_strategy#windows', as: :livestream_strategy_windows

  # ── 營運提醒中心 (Notification Board MVP) ────────────────────────────
  get  '/notification_board',              to: 'notification_board#index',      as: :notification_board
  get  '/notification_board/:id/customers', to: 'notification_board#customers', as: :notification_board_customers
  get  '/notification_board/product_customers', to: 'notification_board#product_customers', as: :notification_board_product_customers
  post '/notification_board/:id/mark_read', to: 'notification_board#mark_read', as: :notification_board_mark_read
  post '/notification_board/:id/assign',              to: 'notification_board#assign',              as: :notification_board_assign
  post '/notification_board/:id/start',                to: 'notification_board#start',                as: :notification_board_start
  post '/notification_board/:id/request_verification', to: 'notification_board#request_verification', as: :notification_board_request_verification
  post '/notification_board/:id/snooze',   to: 'notification_board#snooze',   as: :notification_board_snooze
  post '/notification_board/:id/dismiss',   to: 'notification_board#dismiss',   as: :notification_board_dismiss
  post '/notification_board/:id/create_customer_task', to: 'notification_board#create_customer_task', as: :notification_board_create_customer_task

  # ── Product Registry Review UI (Epic B2-0C) ─────────────────────────
  get   '/product_registry',                    to: 'product_registry#index',          as: :product_registry
  patch '/product_registry/products/:id/inventory', to: 'product_registry#update_inventory', as: :product_registry_inventory
  patch '/product_registry/:id/confirm',         to: 'product_registry#confirm',        as: :confirm_product_registry_mapping
  patch '/product_registry/:id/ignore',          to: 'product_registry#ignore',         as: :ignore_product_registry_mapping
  post  '/product_registry/:id/create_product',  to: 'product_registry#create_product', as: :create_product_registry_mapping

  resources :products, only: [:index, :show], param: :id
  resources :customers, only: [:index, :show] do
    collection do
      get :stats
    end
  end
  resources :customers, only: [:index, :show, :edit, :update]do
    collection { get :stats }
    resources :albums, only: [:index, :show, :new, :create, :edit, :update, :destroy] do
      resources :photos, only: [:create, :destroy]
    end
  end


 





































  get 'pages/page_search'

  get 'intel/intel_analytics_dashboard'
  get 'intel/intel_marketing_dashboard'
  get 'intel/intel_privacy'
  get 'intel/intel_build_notes'
  get 'intel/intel_introduction'

  get 'settings/settings_how_it_works'
  get 'settings/settings_layout_options'
  get 'settings/settings_saving_db'
  get 'settings/settings_skin_options'

  get 'info/info_app_docs'
  get 'info/info_app_licensing'
  get 'info/info_app_flavors'
  get 'info/info_app_docs'

  get 'ui/ui_alerts'
  get 'ui/ui_accordion'
  get 'ui/ui_badges'
  get 'ui/ui_breadcrumbs'
  get 'ui/ui_buttons'
  get 'ui/ui_button_group'
  get 'ui/ui_cards'
  get 'ui/ui_carousel'
  get 'ui/ui_collapse'
  get 'ui/ui_dropdowns'
  get 'ui/ui_list_filter'
  get 'ui/ui_modal'
  get 'ui/ui_navbars'
  get 'ui/ui_panels'
  get 'ui/ui_pagination'
  get 'ui/ui_popovers'
  get 'ui/ui_progress_bars'
  get 'ui/ui_scrollspy'
  get 'ui/ui_side_panel'
  get 'ui/ui_spinners'
  get 'ui/ui_tabs_pills'
  get 'ui/ui_toasts'
  get 'ui/ui_tooltips'

  get 'utilities/utilities_borders'
  get 'utilities/utilities_clearfix'
  get 'utilities/utilities_color_pallet'
  get 'utilities/utilities_display_property'
  get 'utilities/utilities_fonts'
  get 'utilities/utilities_flexbox'
  get 'utilities/utilities_helpers'
  get 'utilities/utilities_position'
  get 'utilities/utilities_responsive_grid'
  get 'utilities/utilities_sizing'
  get 'utilities/utilities_spacing'
  get 'utilities/utilities_typography'

  get 'icons/icons_fontawesome_light'
  get 'icons/icons_fontawesome_regular'
  get 'icons/icons_fontawesome_solid'
  get 'icons/icons_fontawesome_brand'

  get 'icons/icons_nextgen_general'
  get 'icons/icons_nextgen_base'

  get 'icons/icons_stack_showcase'
  get 'icons/icons_stack_generate'

  get 'tables/tables_basic'
  get 'tables/tables_generate_style'

  get 'form/form_basic_inputs'
  get 'form/form_checkbox_radio'
  get 'form/form_input_groups'
  get 'form/form_validation'

  get 'plugins/plugin_faq'
  get 'plugins/plugin_waves'
  get 'plugins/plugin_pacejs'
  get 'plugins/plugin_smartpanels'
  get 'plugins/plugin_bootbox'
  get 'plugins/plugin_slimscroll'
  get 'plugins/plugin_throttle'
  get 'plugins/plugin_navigation'
  get 'plugins/plugin_i18next'
  get 'plugins/plugin_appcore'

  get 'datatables/datatables_basic'
  get 'datatables/datatables_autofill'
  get 'datatables/datatables_buttons'
  get 'datatables/datatables_export'
  get 'datatables/datatables_colreorder'
  get 'datatables/datatables_columnfilter'
  get 'datatables/datatables_fixedcolumns'
  get 'datatables/datatables_fixedheader'
  get 'datatables/datatables_keytable'
  get 'datatables/datatables_responsive'
  get 'datatables/datatables_responsive_alt'
  get 'datatables/datatables_rowgroup'
  get 'datatables/datatables_rowreorder'
  get 'datatables/datatables_scroller'
  get 'datatables/datatables_select'
  get 'datatables/datatables_alteditor'

  get 'statistics/statistics_flot'
  get 'statistics/statistics_chartjs'
  get 'statistics/statistics_chartist'
  get 'statistics/statistics_c3'
  get 'statistics/statistics_peity'
  get 'statistics/statistics_sparkline'
  get 'statistics/statistics_easypiechart'
  get 'statistics/statistics_dygraph'

  get 'notifications/notifications_sweetalert2'
  get 'notifications/notifications_toastr'

  get 'form_plugins/form_plugins_colorpicker'
  get 'form_plugins/form_plugins_datepicker'
  get 'form_plugins/form_plugins_daterange_picker'
  get 'form_plugins/form_plugins_dropzone'
  get 'form_plugins/form_plugins_ionrangeslider'
  get 'form_plugins/form_plugins_inputmask'
  get 'form_plugins/form_plugin_imagecropper'
  get 'form_plugins/form_plugin_select2'
  get 'form_plugins/form_plugin_summernote'

  get 'miscellaneous/miscellaneous_fullcalendar'
  get 'miscellaneous/miscellaneous_lightgallery'

  get 'pages/page_chat'
  get 'pages/page_contacts'
  get 'pages/page_faq'
  get 'pages/page_forum_list'
  get 'pages/page_forum_threads'
  get 'pages/page_forum_discussion'
  get 'pages/page_inbox_general'
  get 'pages/page_inbox_read'
  get 'pages/page_inbox_write'
  get 'pages/page_invoice'

  get 'pages/page_forget'
  get 'pages/page_locked'
  get 'pages/page_login'
  get 'pages/page_login_alt'
  get 'pages/page_register'
  get 'pages/page_confirmation'

  get 'pages/page_error'
  get 'pages/page_error_404'
  get 'pages/page_error_announced'
  get 'pages/page_profile'
end
