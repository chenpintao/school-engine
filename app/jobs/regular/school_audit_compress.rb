# frozen_string_literal: true

module Jobs
  # 审计日志归档压缩（异步，避免阻塞请求）
  class SchoolAuditCompress < ::Jobs::Base
    sidekiq_options retry: 1

    def execute(args)
      path = args[:path]
      return if path.blank?
      ::SchoolEngine::Audit.compress_file(path)
    end
  end
end
