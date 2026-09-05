# frozen_string_literal: true

module ::SchoolEngine
  # Rails::Engine：让插件的 app/controllers、app/views、app/jobs 自动进入 autoload 与 view path
  class Engine < ::Rails::Engine
    engine_name PLUGIN_NAME
    isolate_namespace SchoolEngine

    config.autoload_paths << File.join(config.root, "lib")

    # scheduled job 必须 eager_load，否则 Sidekiq 找不到常量
    # job 定义为 Jobs::SchoolEngine::SchoolMarkGraduates（与路径 app/jobs/scheduled/school_engine 对应）
    scheduled_job_dir = "#{config.root}/app/jobs/scheduled"
    config.to_prepare do
      next unless Dir.exist?(scheduled_job_dir)

      Rails.autoloaders.main.eager_load_dir(scheduled_job_dir)
      sub = "#{scheduled_job_dir}/school_engine"
      Rails.autoloaders.main.eager_load_dir(sub) if Dir.exist?(sub)
    end
  end
end
