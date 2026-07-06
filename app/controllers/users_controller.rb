class UsersController < ApplicationController
  before_action :set_user, only: [:update]

  def index
    @users = User.includes(:role).order(:username)
    @roles = Role.order(:id)
  end

  def new
    @user = User.new
    @roles = Role.order(:id)
  end

  def create
    @user = User.new(user_params)
    if @user.save
      redirect_to users_path, notice: "#{@user.username} 已建立"
    else
      @roles = Role.order(:id)
      render :new, status: :unprocessable_entity
    end
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

  def user_params
    params.require(:user).permit(:username, :email, :password, :password_confirmation, :role_id)
  end
end
