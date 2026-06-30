class MessageTemplatesController < ApplicationController
  before_action :set_template, only: [:update, :destroy]

  def index
    @categories = build_categories
  end

  def create
    @template = MessageTemplate.new(category_key: params.dig(:message_template, :category_key),
                                    subcategory:   params.dig(:message_template, :subcategory).presence,
                                    title:         params.dig(:message_template, :title))
    siblings = MessageTemplate.where(category_key: @template.category_key, subcategory: @template.subcategory)
    @template.position = siblings.maximum(:position).to_i + 1

    if @template.save
      @template.message_template_blocks.create!(block_type: "text", content: "", position: 0)
      render json: { id: @template.id, html: render_card(@template) }
    else
      render json: { error: @template.errors.full_messages.join(", ") }, status: :unprocessable_entity
    end
  end

  def update
    title = params.dig(:message_template, :title)
    @template.update(title: title) if title
    render json: { html: render_card(@template.reload) }
  end

  def destroy
    @template.destroy
    head :no_content
  end

  def reorder
    ids = params[:ids] || []
    ids.each_with_index { |id, i| MessageTemplate.where(id: id).update_all(position: i) }
    head :no_content
  end

  private

  def set_template
    @template = MessageTemplate.find(params[:id])
  end

  def build_categories
    MessageTemplate::CATEGORY_ORDER.map do |key|
      meta = MessageTemplate::CATEGORY_META[key]
      next unless meta

      if key == "bulk"
        subcategories = MessageTemplate::BULK_SUBCATEGORIES.map do |sub_name|
          { name: sub_name, templates: MessageTemplate.in_category(key, sub_name) }
        end
        { key: key, title: meta[:title], icon: meta[:icon], description: meta[:description], subcategories: subcategories }
      else
        { key: key, title: meta[:title], icon: meta[:icon], description: meta[:description], templates: MessageTemplate.in_category(key) }
      end
    end.compact
  end

  def render_card(template)
    render_to_string(partial: "message_templates/message_card", locals: { template: template })
  end
end
