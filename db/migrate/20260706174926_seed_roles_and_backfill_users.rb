class SeedRolesAndBackfillUsers < ActiveRecord::Migration[7.1]
  class MigrationRole < ActiveRecord::Base
    self.table_name = "roles"
  end

  class MigrationUser < ActiveRecord::Base
    self.table_name = "users"
  end

  ROLES = [
    { key: "admin",     name: "Admin" },
    { key: "crm",       name: "CRM" },
    { key: "data",      name: "數據部" },
    { key: "logistics", name: "物流部" },
  ].freeze

  def up
    ROLES.each do |attrs|
      MigrationRole.find_or_create_by!(key: attrs[:key]) { |r| r.name = attrs[:name] }
    end

    admin_role_id = MigrationRole.find_by!(key: "admin").id
    MigrationUser.where(role_id: nil).update_all(role_id: admin_role_id)
  end

  def down
    MigrationRole.where(key: ROLES.map { |r| r[:key] }).destroy_all
  end
end
