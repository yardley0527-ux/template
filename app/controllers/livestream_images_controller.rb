class LivestreamImagesController < ApplicationController
  before_action :set_livestream

  def create
    @image = @livestream.livestream_images.build(image_params)
    if @image.save
      render json: { id: @image.id, url: @image.url }, status: :created
    else
      render json: { errors: @image.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    @image = @livestream.livestream_images.find(params[:id])
    Cloudinary::Api.delete_resources([@image.cloudinary_public_id]) rescue nil
    @image.destroy
    head :no_content
  end

  private

  def set_livestream
    @livestream = Livestream.find(params[:livestream_id])
  end

  def image_params
    params.require(:livestream_image).permit(:cloudinary_public_id, :url, :position)
  end
end
