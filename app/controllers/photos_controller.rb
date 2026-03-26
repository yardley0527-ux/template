class PhotosController < ApplicationController
  before_action :set_customer
  before_action :set_album

  def create
    @photo = @album.photos.build(photo_params)
    if @photo.save
      render json: { message: "照片已上傳" }, status: :created
    else
      render json: { message: "上傳失敗", errors: @photo.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    @photo = @album.photos.find(params[:id])
    # 也從 Cloudinary 刪除
    Cloudinary::Api.delete_resources([@photo.cloudinary_public_id]) rescue nil
    @photo.destroy
    redirect_to customer_album_path(@customer, @album), notice: "照片已刪除"
  end

  private

  def set_customer
    @customer = ShoplineCustomer.find(params[:customer_id])
  end

  def set_album
    @album = @customer.albums.find(params[:album_id])
  end

  def photo_params
    params.require(:photo).permit(:cloudinary_public_id, :url, :caption, :position)
  end
end