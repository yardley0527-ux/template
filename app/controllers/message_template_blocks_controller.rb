class MessageTemplateBlocksController < ApplicationController
  def create
    template = MessageTemplate.find(params[:message_template_id])
    max_pos  = template.message_template_blocks.maximum(:position).to_i
    block    = template.message_template_blocks.create!(
      block_type: params[:block_type].presence_in(%w[text images]) || "text",
      content:    params[:block_type] == "text" ? "" : nil,
      position:   max_pos + 1
    )
    render json: { id: block.id, card_html: render_card(template) }
  end

  def update
    block = MessageTemplateBlock.find(params[:id])
    block.update!(content: params[:content])
    head :no_content
  end

  def destroy
    block = MessageTemplateBlock.find(params[:id])
    template = block.message_template
    block.destroy
    render json: { card_html: render_card(template) }
  end

  def reorder
    ids = params[:ids] || []
    ids.each_with_index { |id, i| MessageTemplateBlock.where(id: id).update_all(position: i) }
    head :no_content
  end

  private

  def render_card(template)
    template.reload
    render_to_string(partial: "message_templates/message_card", locals: { template: template })
  end
end
