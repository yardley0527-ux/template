module CustomersHelper
  def sort_link_tag(label, asc_key, desc_key, current_sort)
    if current_sort == desc_key
      next_sort = asc_key
      arrow = " ▼"
      arrow_style = ""
    elsif current_sort == asc_key
      next_sort = desc_key
      arrow = " ▲"
      arrow_style = ""
    else
      next_sort = desc_key
      arrow = " ⇅"
      arrow_style = "opacity:0.6;"
    end
    link_to customers_path(request.query_parameters.merge(sort: next_sort, page: 1)),
      style: "color:inherit; text-decoration:none;" do
      (label + "<span style='#{arrow_style}'>#{arrow}</span>").html_safe
    end
  end
end