class FetchThreadsPostsJob < ApplicationJob
  queue_as :default

  def perform
    ThreadsScraperService.run
  end
end
