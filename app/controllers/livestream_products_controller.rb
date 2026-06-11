class LivestreamProductsController < ApplicationController
  before_action :set_livestream
  before_action :set_product, only: [:update, :destroy]

  def create
    @product = @livestream.livestream_products.build(product_params)
    if @product.save
      render json: { id: @product.id, name: @product.name, price: @product.price }, status: :created
    else
      render json: { errors: @product.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    if @product.update(product_params)
      render json: { id: @product.id, name: @product.name, price: @product.price }
    else
      render json: { errors: @product.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    @product.destroy
    head :no_content
  end

  private

  def set_livestream
    @livestream = Livestream.find(params[:livestream_id])
  end

  def set_product
    @product = @livestream.livestream_products.find(params[:id])
  end

  def product_params
    params.require(:livestream_product).permit(:name, :price, :position)
  end
end
