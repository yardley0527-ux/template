class LivestreamsController < ApplicationController
  before_action :set_livestream, only: [:edit, :update, :destroy]

  def index
    @livestreams = Livestream.includes(:livestream_images, :livestream_products, :livestream_gifts).all
  end

  def new
    @livestream = Livestream.new
  end

  def create
    @livestream = Livestream.new(livestream_params)
    if @livestream.save
      redirect_to livestreams_path, notice: "直播已建立"
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @livestream.update(livestream_params)
      redirect_to livestreams_path, notice: "直播已更新"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @livestream.destroy
    redirect_to livestreams_path, notice: "直播已刪除"
  end

  private

  def set_livestream
    @livestream = Livestream.find(params[:id])
  end

  def livestream_params
    params.require(:livestream).permit(:date, :notes)
  end
end
