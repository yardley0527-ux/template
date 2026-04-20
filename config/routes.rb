Rails.application.routes.draw do
  devise_for :users, skip: [:registrations], controllers: { sessions: 'users/sessions' }

  root 'welcome#index'
  get "/api/birthday_customers", to: "welcome#birthday_customers"
  get '/livestream_analysis', to: 'livestream_analysis#index'
  resource :metabolism_analysis, only: [:index]
  get 'expiring_members', to: 'expiring_members#index', as: :expiring_members

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
