# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.1].define(version: 2026_06_15_150000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_trgm"
  enable_extension "plpgsql"

  create_table "admins", force: :cascade do |t|
    t.string "email"
    t.string "password_digest"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "albums", force: :cascade do |t|
    t.bigint "shopline_customer_id", null: false
    t.string "name", null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["shopline_customer_id"], name: "index_albums_on_shopline_customer_id"
  end

  create_table "customer_edit_logs", force: :cascade do |t|
    t.bigint "customer_id"
    t.bigint "user_id"
    t.string "customer_name"
    t.string "section"
    t.jsonb "changes_json"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_customer_edit_logs_on_created_at"
    t.index ["customer_id"], name: "index_customer_edit_logs_on_customer_id"
  end

  create_table "customer_merge_logs", force: :cascade do |t|
    t.bigint "orphan_customer_id", null: false
    t.bigint "official_customer_id", null: false
    t.jsonb "orphan_snapshot", default: {}, null: false
    t.integer "reassigned_orders_count", default: 0, null: false
    t.string "merged_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["official_customer_id"], name: "index_customer_merge_logs_on_official_customer_id"
    t.index ["orphan_customer_id"], name: "index_customer_merge_logs_on_orphan_customer_id"
  end

  create_table "customer_profiles", force: :cascade do |t|
    t.integer "shopline_customer_id"
    t.boolean "brand_ambassador_training"
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "health_profile"
    t.boolean "brand_ambassador_blacklisted"
    t.text "feedback"
    t.text "special_attention"
    t.string "product_tags", default: [], null: false, array: true
    t.string "health_tags", default: [], null: false, array: true
    t.datetime "renewal_confirmed_at"
    t.date "renewal_confirmed_for"
    t.index ["health_tags"], name: "index_customer_profiles_on_health_tags", using: :gin
    t.index ["product_tags"], name: "index_customer_profiles_on_product_tags", using: :gin
    t.index ["shopline_customer_id"], name: "index_customer_profiles_on_shopline_customer_id"
  end

  create_table "customer_purchase_summaries", force: :cascade do |t|
    t.string "email", null: false
    t.string "first_product"
    t.string "first_series"
    t.datetime "first_date"
    t.decimal "first_amount", precision: 12, scale: 2
    t.integer "purchase_count", default: 1, null: false
    t.boolean "silent_only", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "first_order_number"
    t.string "second_order_number"
    t.string "second_product"
    t.string "second_series"
    t.datetime "second_date"
    t.datetime "last_order_date"
    t.integer "silent_days_threshold", default: 30, null: false
    t.string "mobile_phone"
    t.string "identity_key", null: false
    t.date "follow_up_week"
    t.boolean "line_bound", default: false, null: false
    t.string "follow_up_product"
    t.index ["email"], name: "index_customer_purchase_summaries_on_email"
    t.index ["first_date"], name: "index_customer_purchase_summaries_on_first_date"
    t.index ["first_order_number"], name: "index_customer_purchase_summaries_on_first_order_number"
    t.index ["first_series"], name: "index_customer_purchase_summaries_on_first_series"
    t.index ["identity_key"], name: "index_customer_purchase_summaries_on_identity_key", unique: true
    t.index ["last_order_date"], name: "index_customer_purchase_summaries_on_last_order_date"
    t.index ["mobile_phone"], name: "index_customer_purchase_summaries_on_mobile_phone"
    t.index ["purchase_count"], name: "index_customer_purchase_summaries_on_purchase_count"
    t.index ["second_series"], name: "index_customer_purchase_summaries_on_second_series"
    t.index ["silent_only"], name: "index_customer_purchase_summaries_on_silent_only"
  end

  create_table "customer_series_loyalties", force: :cascade do |t|
    t.string "email", null: false
    t.string "series", null: false
    t.integer "order_count", default: 0, null: false
    t.decimal "total_amount", precision: 10, scale: 2, default: "0.0"
    t.date "first_date"
    t.date "last_date"
    t.integer "days_since_last"
    t.string "tier"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email", "series"], name: "index_customer_series_loyalties_on_email_and_series", unique: true
    t.index ["series"], name: "index_customer_series_loyalties_on_series"
    t.index ["tier"], name: "index_customer_series_loyalties_on_tier"
  end

  create_table "daily_member_stats", force: :cascade do |t|
    t.date "stat_date", null: false
    t.integer "line_friends", comment: "targetedReaches 好友數"
    t.integer "line_followers", comment: "曾加入好友總計"
    t.integer "line_blocks", comment: "封鎖數"
    t.integer "sl_total_members"
    t.integer "sl_purchased_members"
    t.integer "line_bound_members", comment: "行動會員卡綁定人數"
    t.integer "line_and_sl_members", comment: "官方好友+是網站會員"
    t.integer "unbound_purchased", comment: "手機未綁定但已消費"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["stat_date"], name: "index_daily_member_stats_on_stat_date", unique: true
  end

  create_table "health_assessment_products", force: :cascade do |t|
    t.bigint "shopline_customer_health_assessment_id", null: false
    t.bigint "product_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["product_id"], name: "index_health_assessment_products_on_product_id"
    t.index ["shopline_customer_health_assessment_id"], name: "idx_on_shopline_customer_health_assessment_id_6907628e29"
  end

  create_table "high_spender_follow_ups", force: :cascade do |t|
    t.string "identity_key", null: false
    t.text "note", null: false
    t.datetime "followed_up_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["identity_key"], name: "index_high_spender_follow_ups_on_identity_key"
  end

  create_table "ig_posts", force: :cascade do |t|
    t.bigint "ig_profile_id", null: false
    t.string "shortcode", null: false
    t.text "caption"
    t.integer "likes", default: 0
    t.integer "comments", default: 0
    t.datetime "posted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["ig_profile_id"], name: "index_ig_posts_on_ig_profile_id"
    t.index ["shortcode"], name: "index_ig_posts_on_shortcode", unique: true
  end

  create_table "ig_profiles", force: :cascade do |t|
    t.string "username", null: false
    t.string "display_name"
    t.text "bio"
    t.integer "follower_count", default: 0
    t.integer "following_count", default: 0
    t.integer "post_count", default: 0
    t.string "profile_pic_url"
    t.string "external_url"
    t.boolean "is_verified", default: false
    t.datetime "last_scraped_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["username"], name: "index_ig_profiles_on_username", unique: true
  end

  create_table "ig_snapshots", force: :cascade do |t|
    t.bigint "ig_profile_id", null: false
    t.integer "follower_count", default: 0
    t.integer "post_count", default: 0
    t.date "snapshot_date", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["ig_profile_id", "snapshot_date"], name: "index_ig_snapshots_on_ig_profile_id_and_snapshot_date", unique: true
    t.index ["ig_profile_id"], name: "index_ig_snapshots_on_ig_profile_id"
  end

  create_table "import_runs", force: :cascade do |t|
    t.string "kind", null: false
    t.string "file_name", null: false
    t.string "file_checksum", null: false
    t.jsonb "meta", default: {}, null: false
    t.integer "processed_rows", default: 0, null: false
    t.integer "upserted_rows", default: 0, null: false
    t.integer "skipped_rows", default: 0, null: false
    t.integer "error_rows", default: 0, null: false
    t.jsonb "error_messages", default: [], null: false
    t.datetime "started_at"
    t.datetime "finished_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["kind", "file_checksum"], name: "index_import_runs_on_kind_and_file_checksum"
  end

  create_table "live_events", id: :serial, force: :cascade do |t|
    t.date "event_date", null: false
    t.integer "year", null: false
    t.integer "month", null: false
    t.string "event_name", limit: 100, null: false
    t.text "featured_products"
    t.integer "order_count"
    t.decimal "revenue", precision: 12
    t.text "notes"
    t.datetime "created_at", precision: nil, default: -> { "now()" }
    t.datetime "updated_at", precision: nil, default: -> { "now()" }
  end

  create_table "livestream_gifts", force: :cascade do |t|
    t.bigint "livestream_id", null: false
    t.string "description", null: false
    t.boolean "highlight", default: false, null: false
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["livestream_id"], name: "index_livestream_gifts_on_livestream_id"
  end

  create_table "livestream_images", force: :cascade do |t|
    t.bigint "livestream_id", null: false
    t.string "cloudinary_public_id", null: false
    t.string "url", null: false
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["livestream_id"], name: "index_livestream_images_on_livestream_id"
  end

  create_table "livestream_products", force: :cascade do |t|
    t.bigint "livestream_id", null: false
    t.string "name", null: false
    t.integer "price", null: false
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["livestream_id"], name: "index_livestream_products_on_livestream_id"
  end

  create_table "livestreams", force: :cascade do |t|
    t.date "date", null: false
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["date"], name: "index_livestreams_on_date", unique: true
  end

  create_table "manychat_iguids", force: :cascade do |t|
    t.bigint "manychat_snapshot_id", null: false
    t.string "iguid", null: false
    t.index ["iguid"], name: "index_manychat_iguids_on_iguid"
    t.index ["manychat_snapshot_id"], name: "index_manychat_iguids_on_manychat_snapshot_id"
  end

  create_table "manychat_snapshots", force: :cascade do |t|
    t.string "account_type", null: false
    t.integer "iguid_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "order_gift_records", force: :cascade do |t|
    t.string "order_number"
    t.boolean "gift_sent", default: false, null: false
    t.string "gift_note"
    t.string "updated_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["order_number"], name: "index_order_gift_records_on_order_number", unique: true
  end

  create_table "page_views", force: :cascade do |t|
    t.string "controller_name", null: false
    t.string "action_name", null: false
    t.string "path"
    t.integer "user_id"
    t.datetime "visited_at", null: false
    t.index ["controller_name", "action_name"], name: "index_page_views_on_controller_name_and_action_name"
    t.index ["visited_at"], name: "index_page_views_on_visited_at"
  end

  create_table "photos", force: :cascade do |t|
    t.bigint "album_id", null: false
    t.string "cloudinary_public_id", null: false
    t.string "url", null: false
    t.string "caption"
    t.integer "position", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["album_id", "position"], name: "index_photos_on_album_id_and_position"
    t.index ["album_id"], name: "index_photos_on_album_id"
  end

  create_table "products", force: :cascade do |t|
    t.string "name"
    t.string "category"
    t.string "status"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "shopline_customer_health_assessments", force: :cascade do |t|
    t.bigint "shopline_customer_id", null: false
    t.string "interaction_level"
    t.text "main_health_goal"
    t.text "summary_notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["shopline_customer_id"], name: "idx_on_shopline_customer_id_03d1184d99"
  end

  create_table "shopline_customer_health_questionnaires", force: :cascade do |t|
    t.bigint "shopline_customer_id", null: false
    t.integer "height_cm"
    t.decimal "weight_kg", precision: 5, scale: 1
    t.integer "body_fat_percentage"
    t.string "work_type"
    t.date "birthdate"
    t.string "marital_status"
    t.integer "family_members_count"
    t.text "family_members_details"
    t.string "sleep_time"
    t.string "wake_time"
    t.integer "water_intake_ml"
    t.string "diet_type", default: [], array: true
    t.boolean "take_chinese_medicine"
    t.boolean "bought_our_products"
    t.boolean "bought_other_supplements"
    t.text "previous_weight_loss_methods"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "purchase_reason"
    t.boolean "currently_weight_loss"
    t.string "diet_type_other"
    t.index ["shopline_customer_id"], name: "idx_on_shopline_customer_id_6d5178055d"
  end

  create_table "shopline_customers", force: :cascade do |t|
    t.string "shopline_id"
    t.string "full_name"
    t.string "email"
    t.datetime "joined_at"
    t.string "join_source"
    t.string "language"
    t.integer "order_count"
    t.decimal "total_amount", precision: 10, scale: 2
    t.decimal "issued_shopping_credits", precision: 10, scale: 2
    t.decimal "deducted_shopping_credits", precision: 10, scale: 2
    t.decimal "used_shopping_credits", precision: 10, scale: 2
    t.decimal "current_shopping_credits", precision: 10, scale: 2
    t.integer "issued_points"
    t.integer "deducted_points"
    t.integer "used_points"
    t.integer "current_points"
    t.boolean "is_member"
    t.datetime "member_registered_at"
    t.string "member_registration_source"
    t.string "facebook_id"
    t.string "line_id"
    t.boolean "blacklisted"
    t.boolean "has_password"
    t.boolean "accept_email_marketing"
    t.boolean "accept_sms_marketing"
    t.boolean "accept_fb_marketing"
    t.boolean "accept_line_marketing"
    t.boolean "accept_whatsapp_marketing"
    t.datetime "last_login_at"
    t.string "phone"
    t.string "country_code"
    t.string "mobile_phone"
    t.string "recipient_name"
    t.string "recipient_phone"
    t.string "address_1"
    t.string "address_2"
    t.string "city"
    t.string "state"
    t.string "postal_code"
    t.string "country"
    t.string "membership_level"
    t.date "membership_expiry_date"
    t.string "gender"
    t.date "birthdate"
    t.string "instagram_account"
    t.text "tags"
    t.text "notes"
    t.string "utm_source"
    t.string "utm_medium"
    t.string "utm_source_medium"
    t.string "utm_campaign"
    t.string "utm_term"
    t.string "utm_content"
    t.datetime "utm_clicked_at"
    t.string "referrer_name"
    t.string "referrer_email"
    t.string "referrer_phone"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "personal_note"
    t.bigint "import_run_id"
    t.string "source_row_hash"
    t.index ["email"], name: "index_shopline_customers_on_email", unique: true, where: "(email IS NOT NULL)"
    t.index ["import_run_id"], name: "index_shopline_customers_on_import_run_id"
    t.index ["membership_level"], name: "index_shopline_customers_on_membership_level"
    t.index ["shopline_id"], name: "index_shopline_customers_on_shopline_id", unique: true
    t.index ["source_row_hash"], name: "index_shopline_customers_on_source_row_hash", unique: true
  end

  create_table "shopline_orders", force: :cascade do |t|
    t.string "order_number"
    t.string "product_name"
    t.string "email"
    t.string "instagram_account"
    t.string "payment_status"
    t.string "order_status"
    t.decimal "total_amount", precision: 10, scale: 2
    t.integer "quantity"
    t.string "customer_name"
    t.string "payment_method"
    t.datetime "order_date"
    t.string "utm_source"
    t.string "utm_medium"
    t.string "utm_source_medium"
    t.string "utm_campaign"
    t.string "utm_term"
    t.string "utm_content"
    t.datetime "utm_clicked_at"
    t.string "membership_level"
    t.bigint "shopline_customer_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "import_run_id"
    t.integer "source_year"
    t.integer "source_month"
    t.string "source_row_hash"
    t.decimal "checkout_amount", precision: 10, scale: 2
    t.string "city"
    t.index ["checkout_amount"], name: "index_shopline_orders_on_checkout_amount"
    t.index ["city"], name: "index_shopline_orders_on_city"
    t.index ["email", "order_date"], name: "index_shopline_orders_on_email_and_order_date"
    t.index ["email", "order_number"], name: "index_shopline_orders_on_email_and_order_number"
    t.index ["email"], name: "index_shopline_orders_on_email"
    t.index ["import_run_id"], name: "index_shopline_orders_on_import_run_id"
    t.index ["order_date"], name: "index_shopline_orders_on_order_date"
    t.index ["product_name"], name: "index_shopline_orders_on_product_name_trgm", opclass: :gin_trgm_ops, using: :gin
    t.index ["shopline_customer_id"], name: "index_shopline_orders_on_shopline_customer_id"
    t.index ["source_row_hash"], name: "index_shopline_orders_on_source_row_hash", unique: true
    t.index ["source_year", "source_month"], name: "index_shopline_orders_on_source_year_and_source_month"
  end

  create_table "storage_cn_transactions", force: :cascade do |t|
    t.integer "storage_cn_id"
    t.string "transaction_type"
    t.integer "qty"
    t.string "note"
    t.datetime "created_at"
    t.datetime "updated_at"
    t.string "whodunnit"
    t.date "arrived_at"
    t.string "batch_number"
    t.text "qty_partial_before"
    t.text "qty_partial_after"
    t.integer "qty_before"
  end

  create_table "storage_cns", force: :cascade do |t|
    t.integer "seq"
    t.string "item_no"
    t.string "place"
    t.string "qty"
    t.text "remark"
    t.boolean "notice"
    t.integer "warn"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "part_number"
    t.text "estimated_arrival_date"
    t.integer "qty_full", default: 0
    t.text "qty_partial"
    t.text "made_in"
    t.string "material_size"
    t.text "customer_orders"
  end

  create_table "storage_transactions", force: :cascade do |t|
    t.integer "storage_id"
    t.string "transaction_type"
    t.integer "qty"
    t.string "note"
    t.string "whodunnit"
    t.date "arrived_at"
    t.string "batch_number"
    t.text "qty_partial_before"
    t.text "qty_partial_after"
    t.integer "qty_before"
    t.datetime "created_at"
    t.datetime "updated_at"
  end

  create_table "storages", force: :cascade do |t|
    t.string "seq"
    t.string "itemno"
    t.string "place"
    t.string "qty"
    t.text "remark"
    t.boolean "notice"
    t.integer "warn"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "part_number"
    t.text "estimated_arrival_date"
    t.text "made_in"
    t.string "material_size"
    t.text "customer_orders"
    t.integer "qty_full", default: 0
    t.text "qty_partial"
  end

  create_table "subscriptions", force: :cascade do |t|
    t.bigint "shopline_customer_id", null: false
    t.string "product_name", null: false
    t.string "product_series"
    t.integer "frequency_days", null: false
    t.decimal "discount_rate", precision: 4, scale: 2, null: false
    t.decimal "unit_price", precision: 10, scale: 2, null: false
    t.integer "quantity", default: 1, null: false
    t.string "status", default: "active", null: false
    t.date "started_on", null: false
    t.date "next_due_on", null: false
    t.integer "completed_periods", default: 0, null: false
    t.integer "min_periods", default: 3, null: false
    t.text "notes"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["next_due_on"], name: "index_subscriptions_on_next_due_on"
    t.index ["product_series"], name: "index_subscriptions_on_product_series"
    t.index ["shopline_customer_id"], name: "index_subscriptions_on_shopline_customer_id"
    t.index ["status"], name: "index_subscriptions_on_status"
  end

  create_table "threads_analyses", force: :cascade do |t|
    t.date "fetched_on", null: false
    t.text "ai_summary"
    t.jsonb "stats_json", default: []
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["fetched_on"], name: "index_threads_analyses_on_fetched_on", unique: true
  end

  create_table "threads_posts", force: :cascade do |t|
    t.string "post_id", null: false
    t.string "username"
    t.string "full_name"
    t.text "text_content"
    t.integer "like_count", default: 0
    t.integer "reply_count", default: 0
    t.integer "repost_count", default: 0
    t.string "post_url"
    t.string "keyword"
    t.datetime "posted_at"
    t.date "fetched_on"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["fetched_on"], name: "index_threads_posts_on_fetched_on"
    t.index ["keyword"], name: "index_threads_posts_on_keyword"
    t.index ["post_id"], name: "index_threads_posts_on_post_id", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "username", default: "", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
    t.index ["username"], name: "index_users_on_username", unique: true
  end

  create_table "versions", force: :cascade do |t|
    t.string "item_type", null: false
    t.bigint "item_id", null: false
    t.string "event", null: false
    t.string "whodunnit"
    t.text "object"
    t.datetime "created_at", precision: nil
    t.text "object_changes"
    t.index ["item_type", "item_id"], name: "index_versions_on_item_type_and_item_id"
  end

  add_foreign_key "albums", "shopline_customers"
  add_foreign_key "health_assessment_products", "products"
  add_foreign_key "health_assessment_products", "shopline_customer_health_assessments"
  add_foreign_key "ig_posts", "ig_profiles"
  add_foreign_key "ig_snapshots", "ig_profiles"
  add_foreign_key "livestream_gifts", "livestreams"
  add_foreign_key "livestream_images", "livestreams"
  add_foreign_key "livestream_products", "livestreams"
  add_foreign_key "manychat_iguids", "manychat_snapshots"
  add_foreign_key "photos", "albums"
  add_foreign_key "shopline_customer_health_assessments", "shopline_customers"
  add_foreign_key "shopline_customer_health_questionnaires", "shopline_customers"
  add_foreign_key "shopline_orders", "shopline_customers"
end
