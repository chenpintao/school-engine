# frozen_string_literal: true

module Jobs
  # 异步 AI 审核任务：不影响发帖同步链路
  class SchoolAiReview < ::Jobs::Base
    sidekiq_options retry: 2

    def execute(args)
      post = Post.find_by(id: args[:post_id])
      return if post.nil?
      ::SchoolEngine::AiReview.process!(post)
    end
  end
end
