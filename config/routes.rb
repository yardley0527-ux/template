Rails.application.routes.draw do
  devise_for :users, skip: [:registrations], controllers: { sessions: 'users/sessions' }

  root 'welcome#index'

  resources :livestreams, only: [:index, :new, :create, :edit, :update, :destroy] do
    resources :livestream_images, only: [:create, :destroy]
    resources :livestream_products, only: [:create, :update, :destroy]
    resources :livestream_gifts, only: [:create, :update, :destroy]
  end
  get '/monitoring',          to: 'monitoring#index',           as: :monitoring
  get  '/high_value_orders',        to: 'high_value_orders#index',    as: :high_value_orders
  get  '/daily_orders',             to: 'daily_orders#index',         as: :daily_orders
  get  '/daily_orders/export',      to: 'daily_orders#export',        as: :export_daily_orders
  post '/daily_orders/toggle_customer_flag', to: 'daily_orders#toggle_customer_flag', as: :toggle_daily_orders_customer_flag
  post '/order_gift_records/upsert', to: 'order_gift_records#upsert',  as: :upsert_order_gift_record
  get  '/member_contacts',                to: 'member_contacts#index',          as: :member_contacts
  get  '/member_contacts/export',        to: 'member_contacts#export',         as: :member_contacts_export
  post '/member_contacts/refresh_line',  to: 'member_contacts#refresh_line',   as: :member_contacts_refresh_line
  post '/member_contacts/update_sl',     to: 'member_contacts#update_sl',      as: :member_contacts_update_sl
  get  '/ig_dashboard',             to: 'ig_dashboard#index',         as: :ig_dashboard
  get  '/ig_followers',             to: 'ig_followers#index',         as: :ig_followers
  get  '/ads_dashboard',            to: 'ads_dashboard#index',        as: :ads_dashboard
  resources :kocs, only: [:index, :create, :update, :destroy]
  resources :relove_kocs, only: [:index, :create, :update, :destroy]
  get  '/line_broadcast',           to: 'line_broadcast#index',       as: :line_broadcast
  resources :line_broadcast_highlights, only: [:create, :destroy]
  get  '/ig_audience',              to: 'ig_audience#index',          as: :ig_audience
  get  '/ig_audience/detail',       to: 'ig_audience#detail',         as: :ig_audience_detail
  get  '/ig_audience/export',       to: 'ig_audience#export',         as: :ig_audience_export
  get  '/ig_audience/export_no_line', to: 'ig_audience#export_no_line', as: :ig_audience_export_no_line
  get  '/ig_audience/export_with_line', to: 'ig_audience#export_with_line', as: :ig_audience_export_with_line
  get  '/ig_audience/export_high_value_silent', to: 'ig_audience#export_high_value_silent', as: :ig_audience_export_high_value_silent
  post '/ig_dashboard/refresh',     to: 'ig_dashboard#refresh',       as: :ig_dashboard_refresh
  get  '/threads_dashboard',             to: 'threads_dashboard#index',     as: :threads_dashboard
  post '/threads_dashboard/refresh',    to: 'threads_dashboard#refresh',   as: :threads_dashboard_refresh
  post '/threads_dashboard/reanalyze',  to: 'threads_dashboard#reanalyze', as: :threads_dashboard_reanalyze
  get  '/threads_dashboard/test_api',   to: 'threads_dashboard#test_api',  as: :threads_dashboard_test_api
  patch  '/threads_dashboard/posts/:id/toggle_commented', to: 'threads_dashboard#toggle_commented', as: :threads_dashboard_toggle_commented
  delete '/threads_dashboard/posts/:id',                  to: 'threads_dashboard#destroy_post',     as: :threads_dashboard_post
  get    '/threads_dashboard/hidden',                     to: 'threads_dashboard#hidden_posts',     as: :threads_dashboard_hidden
  patch  '/threads_dashboard/posts/:id/restore',          to: 'threads_dashboard#restore_post',     as: :threads_dashboard_restore_post
  get "/api/birthday_customers", to: "welcome#birthday_customers"
  get '/livestream_analysis', to: 'livestream_analysis#index', as: :livestream_analysis
  get '/turmeric_analysis',                to: 'turmeric_analysis#index',          as: :turmeric_analysis
  get '/turmeric_analysis/export_missing', to: 'turmeric_analysis#export_missing',  as: :turmeric_export_missing
  get '/turmeric_analysis/export_event',   to: 'turmeric_analysis#export_event',    as: :turmeric_export_event
  get '/metabolism_analysis',                to: 'metabolism_analysis#index',          as: :metabolism_analysis
  get '/metabolism_analysis/export_missing', to: 'metabolism_analysis#export_missing', as: :metabolism_export_missing
  get '/metabolism_analysis/export_event',   to: 'metabolism_analysis#export_event',   as: :metabolism_export_event
  get '/glutathione_analysis',                to: 'glutathione_analysis#index',          as: :glutathione_analysis
  get '/glutathione_analysis/export_missing', to: 'glutathione_analysis#export_missing',  as: :glutathione_export_missing
  get '/glutathione_analysis/export_event',   to: 'glutathione_analysis#export_event',    as: :glutathione_export_event
  get '/probiotic_analysis',                to: 'probiotic_analysis#index',          as: :probiotic_analysis
  get '/probiotic_analysis/export_missing', to: 'probiotic_analysis#export_missing',  as: :probiotic_export_missing
  get '/probiotic_analysis/export_event',   to: 'probiotic_analysis#export_event',    as: :probiotic_export_event
  get '/probiotic_analysis/export_action',  to: 'probiotic_analysis#export_action',   as: :probiotic_export_action
  get '/omnipotent_analysis',                to: 'omnipotent_analysis#index',          as: :omnipotent_analysis
  get '/omnipotent_analysis/export_missing',    to: 'omnipotent_analysis#export_missing',    as: :omnipotent_export_missing
  get '/omnipotent_analysis/export_event',     to: 'omnipotent_analysis#export_event',      as: :omnipotent_export_event
  get '/omnipotent_analysis/export_whitening', to: 'omnipotent_analysis#export_whitening',  as: :omnipotent_export_whitening
  get '/omnipotent_restock',                  to: 'omnipotent_restock#index',            as: :omnipotent_restock
  get '/omnipotent_restock/export',           to: 'omnipotent_restock#export',           as: :omnipotent_restock_export
  get '/omnipotent_restock/export_at_risk',   to: 'omnipotent_restock#export_at_risk',   as: :omnipotent_restock_export_at_risk
  get '/omnipotent_restock/export_loyal',     to: 'omnipotent_restock#export_loyal',     as: :omnipotent_restock_export_loyal
  get 'customers/export_inactive',         to: 'customers#export_inactive',         as: :export_inactive_customers
  get 'customers/export_credits_expiring', to: 'customers#export_credits_expiring', as: :export_credits_expiring_customers

  resources :expiring_members, only: [:index] do
    post :confirm_renewal, on: :member
  end  
  get '/first_purchase', to: 'first_purchase#index', as: :first_purchase_index
  get '/loyal_customers',            to: 'loyal_customers#index',      as: :loyal_customers
  get '/inactive_members',           to: 'inactive_members#index',     as: :inactive_members
  get  '/duplicate_customers',         to: 'duplicate_customers#index', as: :duplicate_customers
  post '/duplicate_customers/merge',   to: 'duplicate_customers#merge', as: :merge_duplicate_customers
  get '/product_strategy',      to: 'product_strategy#index',      as: :product_strategy
  get '/subscription_strategy', to: 'subscription_strategy#index', as: :subscription_strategy
  get   '/high_spender_first_purchase',             to: 'high_spender_first_purchase#index',       as: :high_spender_first_purchase
  post  '/high_spender_first_purchase/snapshot',    to: 'high_spender_first_purchase#snapshot',    as: :high_spender_first_purchase_snapshot
  patch '/high_spender_first_purchase/update_field', to: 'high_spender_first_purchase#update_field', as: :high_spender_first_purchase_update_field
  post '/high_spender_follow_ups',              to: 'high_spender_follow_ups#create',        as: :high_spender_follow_ups
  get '/shopping_credits',    to: 'shopping_credits#index',    as: :shopping_credits
  get '/livestream_strategy', to: 'livestream_strategy#index', as: :livestream_strategy

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
