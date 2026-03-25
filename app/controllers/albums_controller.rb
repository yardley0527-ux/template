class AlbumsController < ApplicationController
  before_action :set_customer
  before_action :set_album, only: [:show, :edit, :update, :destroy]

  def index
    @albums = @customer.albums.includes(:photos)
  end

  def show
    @photos = @album.photos
  end

  def new
    @album = @customer.albums.build
  end

  def create
    @album = @customer.albums.build(album_params)
    if @album.save
      redirect_to customer_album_path(@customer, @album), notice: "相簿已建立"
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @album.update(album_params)
      redirect_to customer_album_path(@customer, @album), notice: "已更新"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @album.destroy
    redirect_to customer_path(@customer), notice: "相簿已刪除"
  end

  private

  def set_customer
    @customer = ShoplineCustomer.find(params[:customer_id])
  end

  def set_album
    @album = @customer.albums.find(params[:id])
  end

  def album_params
    params.require(:album).permit(:name, :description)
  end
end