class FaqImagesController < ApplicationController
  def create
    faq = Faq.find(image_params[:faq_id])

    position = faq.faq_images.maximum(:position).to_i + 1
    img = faq.faq_images.create!(
      cloudinary_public_id: image_params[:cloudinary_public_id],
      url: image_params[:url],
      position: position
    )

    render json: { id: img.id, url: img.url, html: render_card(faq.reload) }
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def destroy
    img = FaqImage.find(params[:id])
    faq = img.faq
    Cloudinary::Api.delete_resources([img.cloudinary_public_id]) rescue nil
    img.destroy

    render json: { html: render_card(faq.reload) }
  end

  private

  def image_params
    params.require(:faq_image).permit(:faq_id, :cloudinary_public_id, :url)
  end

  def render_card(faq)
    render_to_string(partial: "faqs/faq_card", locals: { faq: faq, hue: faq.faq_category.hue })
  end
end
