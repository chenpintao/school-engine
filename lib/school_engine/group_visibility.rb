# frozen_string_literal: true

module SchoolEngine
  # 班级圈群组成员隐藏：
  # 你知道这是本班群组，但看不到群里还有谁。
  # members 接口对非 staff 一律 404（staff 保留管理溯源能力）；前端同步隐藏成员 tab 与人数。
  module GroupVisibility
    # 班级圈组名：xx-2026-3 / cz-2026-3（normalize 后可能带后缀，只匹配前缀）
    CLASS_CIRCLE_NAME_REGEX = /\A(?:xx|cz)-\d{4}-/

    def self.class_circle_name?(name)
      name.to_s.match?(CLASS_CIRCLE_NAME_REGEX)
    end

    module GroupsControllerExtension
      # GET /groups/:group_id/members
      def members
        if class_circle_request? && !current_user&.staff?
          raise Discourse::NotFound
        end
        super
      end

      private

      def class_circle_request?
        raw = params[:group_id].to_s
        name =
          if raw.match?(/\A\d+\z/)
            Group.where(id: raw).pick(:name).to_s
          else
            raw
          end
        SchoolEngine::GroupVisibility.class_circle_name?(name)
      end
    end
  end
end
