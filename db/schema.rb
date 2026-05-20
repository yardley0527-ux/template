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

ActiveRecord::Schema[7.1].define(version: 2026_05_20_120000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

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
  end

  create_table "users", force: :cascade do |t|
    t.string "account"
    t.string "password"
    t.string "name"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "authentication", default: 1
    t.string "location"
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

  add_foreign_key "ig_posts", "ig_profiles"
  add_foreign_key "ig_snapshots", "ig_profiles"
end
