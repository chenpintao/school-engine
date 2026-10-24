# frozen_string_literal: true

module Jobs
  module SchoolEngine
    class SchoolModerationSla < ::Jobs::Scheduled
      every 15.minutes

      def execute(_args)
        now = Time.zone.now

        # 限时隐藏到期 → 转入人工复核（不自动公开，避免"到期即放行"）
        PostCustomField
          .where(name: "mod_expires_at")
          .where("value < ?", now.iso8601)
          .find_each do |cf|
            begin
              post = Post.find_by(id: cf.post_id)
              next if post.nil?
              next unless %w[pending hidden].include?(post.custom_fields["mod_state"])
              expires = ::SchoolEngine::Moderation.parse_time(cf.value)
              next if expires.nil? || expires > now
              ::SchoolEngine::Moderation.apply_action!(
                post,
                state: "escalated",
                action: "review",
                actor: User.system_user,
                note: "限时隐藏到期，转入人工复核",
              )
            rescue => e
              Rails.logger.warn("school-engine: 过期隐藏处理失败 post=#{cf.post_id}: #{e.message}")
            end
          end

        # SLA 逾期 → 升级并提醒复核组
        PostCustomField
          .where(name: "mod_deadline")
          .where("value < ?", now.iso8601)
          .find_each do |cf|
            begin
              post = Post.find_by(id: cf.post_id)
              next if post.nil?
              deadline = ::SchoolEngine::Moderation.parse_time(cf.value)
              next if deadline.nil? || deadline > now
              next unless ::SchoolEngine::Moderation.overdue?(post)
              cats = post.custom_fields["report_cats"].to_s.split(",")
              post.custom_fields["mod_state"] = "escalated"
              ::SchoolEngine::Moderation.log_event!(post, "sla_overdue", { "by" => -1 })
              post.save_custom_fields(true)
              ::SchoolEngine::Moderation.notify_staff_high_risk!(post, cats)
            rescue => e
              Rails.logger.warn("school-engine: SLA 逾期处理失败 post=#{cf.post_id}: #{e.message}")
            end
          end
      end
    rescue => e
      Rails.logger.warn("school-engine: SLA 任务异常 #{e.class}: #{e.message}")
    end
  end
end
