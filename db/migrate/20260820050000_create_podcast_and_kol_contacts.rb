# 業配名單下新增兩頁：Podcast 聯絡名單、KOL、藝人聯絡名單，模板比照 kocs/relove_kocs。
class CreatePodcastAndKolContacts < ActiveRecord::Migration[7.1]
  class MigrationRole < ActiveRecord::Base
    self.table_name = "roles"
  end

  class MigrationPagePermission < ActiveRecord::Base
    self.table_name = "page_permissions"
  end

  class MigrationPodcastContact < ActiveRecord::Base
    self.table_name = "podcast_contacts"
  end

  class MigrationKolContact < ActiveRecord::Base
    self.table_name = "kol_contacts"
  end

  def up
    create_table :podcast_contacts do |t|
      t.string "ig_username"
      t.string "ig_full_name"
      t.string "email"
      t.string "alias"
      t.string "profile_url"
      t.string "status"
      t.text "notes"
      t.string "source"
      t.boolean "follows_chloe_ig", default: false, null: false
      t.boolean "follows_official_ig", default: false, null: false
      t.boolean "email_sent", default: false, null: false
      t.text "logistics_notes"
      t.date "pr_gift_shipped_at"
      t.timestamps
      t.index :ig_username, unique: true
    end

    create_table :kol_contacts do |t|
      t.string "ig_username"
      t.string "ig_full_name"
      t.string "email"
      t.string "alias"
      t.string "profile_url"
      t.string "status"
      t.text "notes"
      t.string "source"
      t.boolean "follows_chloe_ig", default: false, null: false
      t.boolean "follows_official_ig", default: false, null: false
      t.boolean "email_sent", default: false, null: false
      t.text "logistics_notes"
      t.date "pr_gift_shipped_at"
      t.timestamps
      t.index :ig_username, unique: true
    end

    role = MigrationRole.find_by(key: "crm")
    if role
      MigrationPagePermission.find_or_create_by!(role_id: role.id, controller_name: "podcast_contacts")
      MigrationPagePermission.find_or_create_by!(role_id: role.id, controller_name: "kol_contacts")
    end

    %w[bowie0221 sinceremuer].each do |username|
      MigrationPodcastContact.find_or_create_by!(ig_username: username) do |c|
        c.status = "待接洽"
        c.source = "手動新增"
      end
    end

    %w[woo_hsiang_chun eatzzz7].each do |username|
      MigrationKolContact.find_or_create_by!(ig_username: username) do |c|
        c.status = "待接洽"
        c.source = "手動新增"
      end
    end
  end

  def down
    role = MigrationRole.find_by(key: "crm")
    if role
      MigrationPagePermission.where(role_id: role.id, controller_name: %w[podcast_contacts kol_contacts]).destroy_all
    end

    drop_table :kol_contacts
    drop_table :podcast_contacts
  end
end
