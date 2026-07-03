class MessageTemplateImagesController < ApplicationController
  def create
    block = MessageTemplateBlock.find(image_params[:message_template_block_id])

    position = block.message_template_images.maximum(:position).to_i + 1
    img = block.message_template_images.create!(
      cloudinary_public_id: image_params[:cloudinary_public_id],
      url: image_params[:url],
      position: position
    )

    card_html = render_to_string(
      partial: "message_templates/message_card",
      locals: { template: block.message_template.reload }
    )

    render json: { id: img.id, url: img.url, card_html: card_html }
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def destroy
    img   = MessageTemplateImage.find(params[:id])
    block = img.message_template_block
    Cloudinary::Api.delete_resources([img.cloudinary_public_id]) rescue nil
    img.destroy

    card_html = render_to_string(
      partial: "message_templates/message_card",
      locals: { template: block.message_template.reload }
    )
    render json: { card_html: card_html }
  end

  private

  def image_params
    params.require(:message_template_image).permit(:message_template_block_id, :cloudinary_public_id, :url)
  end
end
