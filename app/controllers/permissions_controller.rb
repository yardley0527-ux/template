class PermissionsController < ApplicationController
  def index
    @roles  = Role.where.not(key: Role::ADMIN_KEY).order(:id)
    @groups = PageRegistry.groups
    @granted = PagePermission.pluck(:role_id, :controller_name)
                             .each_with_object(Hash.new { |h, k| h[k] = [] }) do |(role_id, controller_name), acc|
                               acc[role_id] << controller_name
                             end
  end

  def update
    Role.where.not(key: Role::ADMIN_KEY).find_each do |role|
      selected = Array(params.dig(:permissions, role.id.to_s)).uniq & PageRegistry.all_controllers
      current  = role.page_permissions.pluck(:controller_name)

      (selected - current).each { |c| role.page_permissions.create!(controller_name: c) }

      to_remove = current - selected
      role.page_permissions.where(controller_name: to_remove).destroy_all if to_remove.any?
    end

    redirect_to permissions_path, notice: "權限設定已更新"
  end
end
