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

ActiveRecord::Schema[7.1].define(version: 2026_04_21_093854) do
  # These are extensions that must be enabled in order to support this database
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
    t.index ["email"], name: "index_customer_purchase_summaries_on_email", unique: true
    t.index ["first_date"], name: "index_customer_purchase_summaries_on_first_date"
    t.index ["first_order_number"], name: "index_customer_purchase_summaries_on_first_order_number"
    t.index ["first_series"], name: "index_customer_purchase_summaries_on_first_series"
    t.index ["last_order_date"], name: "index_customer_purchase_summaries_on_last_order_date"
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

  create_table "health_assessment_products", force: :cascade do |t|
    t.bigint "shopline_customer_health_assessment_id", null: false
    t.bigint "product_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["product_id"], name: "index_health_assessment_products_on_product_id"
    t.index ["shopline_customer_health_assessment_id"], name: "idx_on_shopline_customer_health_assessment_id_6907628e29"
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
    t.index ["shopline_customer_id"], name: "index_shopline_orders_on_shopline_customer_id"
    t.index ["source_row_hash"], name: "index_shopline_orders_on_source_row_hash", unique: true
    t.index ["source_year", "source_month"], name: "index_shopline_orders_on_source_year_and_source_month"
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

  add_foreign_key "albums", "shopline_customers"
  add_foreign_key "health_assessment_products", "products"
  add_foreign_key "health_assessment_products", "shopline_customer_health_assessments"
  add_foreign_key "photos", "albums"
  add_foreign_key "shopline_customer_health_assessments", "shopline_customers"
  add_foreign_key "shopline_customer_health_questionnaires", "shopline_customers"
  add_foreign_key "shopline_orders", "shopline_customers"
end
