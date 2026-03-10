module CustomersHelper
  def sort_link_tag(label, asc_key, desc_key, current_sort)
    if current_sort == desc_key
      next_sort = asc_key
      arrow = " ▼"
    elsif current_sort == asc_key
      next_sort = desc_key
      arrow = " ▲"
    else
      next_sort = desc_key
      arrow = ""
    end
    link_to label + arrow,
      customers_path(request.query_parameters.merge(sort: next_sort, page: 1)),
      style: "color:inherit; text-decoration:none;"
  end
end