# frozen_string_literal: true

module Jobs
  module SchoolEngine
    # 学期末时光胶囊：每日检查，仅在站点设置的两个学期末月-日当天触发，
    # 给本学期有胶囊内容的用户私信发送学期报告
    class SchoolSemesterCapsule < ::Jobs::Scheduled
      every 1.day

      def execute(args = nil)
        return unless SiteSetting.school_engine_enabled

        window = semester_window(Date.current)
        return unless window

        label, since = window
        SchoolEngine::Featured.user_ids_with_capsule(since: since).each do |user_id|
          user = User.find_by(id: user_id)
          next unless user&.human?

          posts =
            SchoolEngine::Featured.capsule_posts_for(
              user,
              since: since,
              include_anonymous: true,
            ).to_a
          next if posts.empty?

          SchoolEngine::Messages.semester_capsule!(user, posts, label)
        rescue => e
          Rails.logger.error(
            "school-engine: 学期胶囊发送失败 user=#{user_id}: #{e.message}\n#{e.backtrace.first(10).join("\n")}",
          )
        end
      end

      private

      # 返回 [学期名称, 内容统计起始日]；今天不是学期末则返回 nil
      # 第一学期末（默认 1-31）：统计上一年 9-01 起；第二学期末（默认 7-31）：统计当年 2-01 起
      def semester_window(today)
        [[SiteSetting.school_engine_semester_end_1, "第一学期", ->(y) { Date.new(y - 1, 9, 1) }],
         [SiteSetting.school_engine_semester_end_2, "第二学期", ->(y) { Date.new(y, 2, 1) }]].each do |setting, label, since_fn|
          month, day = setting.to_s.split("-").map(&:to_i)
          next if month.nil? || day.nil?
          return [label, since_fn.call(today.year)] if today.month == month && today.day == day
        end
        nil
      end
    end
  end
end
