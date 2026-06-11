class LivestreamGiftsController < ApplicationController
  before_action :set_livestream
  before_action :set_gift, only: [:update, :destroy]

  def create
    @gift = @livestream.livestream_gifts.build(gift_params)
    if @gift.save
      render json: { id: @gift.id, description: @gift.description, highlight: @gift.highlight }, status: :created
    else
      render json: { errors: @gift.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    if @gift.update(gift_params)
      render json: { id: @gift.id, description: @gift.description, highlight: @gift.highlight }
    else
      render json: { errors: @gift.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    @gift.destroy
    head :no_content
  end

  private

  def set_livestream
    @livestream = Livestream.find(params[:livestream_id])
  end

  def set_gift
    @gift = @livestream.livestream_gifts.find(params[:id])
  end

  def gift_params
    params.require(:livestream_gift).permit(:description, :highlight, :position)
  end
end
