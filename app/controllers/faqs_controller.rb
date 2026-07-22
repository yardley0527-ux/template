class FaqsController < ApplicationController
  before_action :set_faq, only: [:update, :destroy]

  def index
    @categories = FaqCategory.order(:position).includes(faqs: :faq_images)
  end

  def create
    category = FaqCategory.find(params.dig(:faq, :faq_category_id))
    position = category.faqs.maximum(:position).to_i + 1
    faq = category.faqs.create!(question: params.dig(:faq, :question).presence || "新問題", position: position)
    render json: { id: faq.id, html: render_card(faq) }
  rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def update
    attrs = faq_params
    attrs = attrs.except(:question) if attrs[:question].blank?
    @faq.update!(attrs)
    render json: { html: render_card(@faq.reload) }
  end

  def destroy
    @faq.destroy
    head :no_content
  end

  def reorder
    ids = params[:ids] || []
    ids.each_with_index { |id, i| Faq.where(id: id).update_all(position: i) }
    head :no_content
  end

  private

  def set_faq
    @faq = Faq.find(params[:id])
  end

  def faq_params
    params.require(:faq).permit(:question, :answer)
  end

  def render_card(faq)
    render_to_string(partial: "faqs/faq_card", locals: { faq: faq })
  end
end
