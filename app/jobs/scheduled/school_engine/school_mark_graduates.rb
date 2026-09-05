# frozen_string_literal: true

module Jobs
  module SchoolEngine
    # 班级圈日常维护：每年 7月1日 毕业标记 + 每天刷新班级圈显示名（随 diff 变动）
    class SchoolMarkGraduates < ::Jobs::Scheduled
      every 1.day

      def execute(args = nil)
        return unless SiteSetting.school_engine_enabled

        begin
          SchoolEngine::ClassCircle.update_circle_display_names
        rescue => e
          Rails.logger.error("school-engine: 刷新班级圈显示名失败: #{e.message}")
        end

        begin
          SchoolEngine::ClassCircle.mark_graduates
        rescue => e
          Rails.logger.error("school-engine: 毕业标记任务失败: #{e.message}\n#{e.backtrace.join("\n")}")
        end
      end
    end
  end
end
