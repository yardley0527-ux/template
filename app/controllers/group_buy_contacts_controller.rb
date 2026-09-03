class GroupBuyContactsController < ApplicationController
  before_action :set_contact, only: [:edit, :update, :destroy]

  def index
    @selected_status = params[:status].presence
    scope = GroupBuyContact.all
    scope = scope.where(status: @selected_status) if @selected_status
    @contacts = scope

    @counts = GroupBuyContact.unscope(:order).group(:status).count
  end

  def new
    @contact = GroupBuyContact.new
  end

  def create
    @contact = GroupBuyContact.new(contact_params)
    if @contact.save
      redirect_to group_buy_contacts_path, notice: "已新增"
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @contact.update(contact_params)
      redirect_to group_buy_contacts_path, notice: "已更新"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @contact.destroy
    redirect_to group_buy_contacts_path, notice: "已刪除"
  end

  private

  def set_contact
    @contact = GroupBuyContact.find(params[:id])
  end

  def contact_params
    params.require(:group_buy_contact).permit(
      :brand_name, :product, :channel, :contact_handle,
      :contacted_on, :status, :follow_up_on, :notes
    )
  end
end
