class UsersController < ApplicationController
  before_action :set_user, only: [:update]

  def index
    @users = User.includes(:role).order(:username)
    @roles = Role.order(:id)
  end

  def update
    role = Role.find_by(id: params[:user][:role_id])
    @user.update!(role: role)
    redirect_to users_path, notice: "#{@user.username} 的角色已更新"
  end

  private

  def set_user
    @user = User.find(params[:id])
  end
end
