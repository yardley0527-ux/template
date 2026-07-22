class FaqCategoriesController < ApplicationController
  def create
    name = params.dig(:faq_category, :name).presence || "新分類"
    position = FaqCategory.maximum(:position).to_i + 1
    category = FaqCategory.create!(name: name, position: position)
    render json: { id: category.id, name: category.name }
  end

  def update
    category = FaqCategory.find(params[:id])
    category.update!(name: params.dig(:faq_category, :name))
    render json: { id: category.id, name: category.name }
  end

  def destroy
    FaqCategory.find(params[:id]).destroy
    head :no_content
  end

  def reorder
    ids = params[:ids] || []
    ids.each_with_index { |id, i| FaqCategory.where(id: id).update_all(position: i) }
    head :no_content
  end
end
