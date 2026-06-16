class LineBroadcastController < ApplicationController
  def index
    json_path = Rails.root.join('data', 'line_broadcast_data.json')
    @data = File.exist?(json_path) ? JSON.parse(File.read(json_path)) : default_data
    @broadcasts = (@data['broadcasts'] || []).sort_by { |b| b['push_time'] }

    @total_broadcasts = @broadcasts.size
    @total_revenue    = @broadcasts.sum { |b| b['revenue'].to_f }
    @total_orders     = @broadcasts.sum { |b| b['orders'].to_i }
    @avg_ctr          = avg(@broadcasts.map { |b| b['ctr'].to_f })
    @avg_read_rate    = avg(@broadcasts.map { |b| b['read_rate'].to_f })
    @avg_unsub_rate   = avg(@broadcasts.map { |b| b['unsubscribe_rate'].to_f })

    @top_revenue = @broadcasts.sort_by { |b| -b['revenue'].to_f }.first(10)
    @top_ctr     = @broadcasts.sort_by { |b| -b['ctr'].to_f }.first(10)

    @monthly = @broadcasts.group_by { |b| b['push_time'].to_s[0..6] }.sort.map do |month, rows|
      {
        month: month,
        broadcasts: rows.size,
        revenue: rows.sum { |b| b['revenue'].to_f },
        orders: rows.sum { |b| b['orders'].to_i },
        avg_ctr: avg(rows.map { |b| b['ctr'].to_f })&.round(2),
        avg_read_rate: avg(rows.map { |b| b['read_rate'].to_f })&.round(2)
      }
    end
  end

  private

  def avg(arr)
    arr = arr.select { |v| v && v > 0 }
    arr.empty? ? nil : (arr.sum / arr.size.to_f)
  end

  def default_data
    { 'broadcasts' => [], 'last_updated' => nil, 'product' => '', 'channel' => 'LINE 官方帳號' }
  end
end
