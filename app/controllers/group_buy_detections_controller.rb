class GroupBuyDetectionsController < ApplicationController
  before_action :set_detection

  def edit
  end

  def update
    if @detection.update(detection_params)
      redirect_to group_buy_posts_path(status: params[:redirect_status]), notice: "已更新"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def set_detection
    @detection = GroupBuyDetection.find(params[:id])
  end

  def detection_params
    params.require(:group_buy_detection).permit(:status, :detected_brand, :detected_product_name, :note)
  end
end
