# frozen_string_literal: true

module SchoolEngine
  # 系统私信通知（以 system 用户发送）
  module Messages
    def self.featured_post_notification!(post)
      return if post.nil? || post.user.nil? || post.user.id < 0

      PostCreator.create!(
        User.system_user,
        title: I18n.t("school_engine.pm.featured_title"),
        raw:
          I18n.t(
            "school_engine.pm.featured_body",
            topic_title: post.topic.title,
            url: "#{Discourse.base_url}#{post.url}",
          ),
        archetype: Archetype.private_message,
        target_usernames: post.user.username,
        skip_validations: true,
      )
    rescue => e
      Rails.logger.warn(
        "school-engine: 精选私信发送失败 post=#{post&.id} user=#{post&.user_id}: #{e.message}",
      )
      nil
    end

    # 学期末时光胶囊报告（posts 为 Post 关系/数组；仅发给作者本人，可含其匿名精选帖）
    def self.semester_capsule!(user, posts, semester_label)
      list = capsule_lines(posts)
      featured_count = posts.count { |p| p.custom_fields[Featured::CF_FEATURED] == "true" }
      send_capsule_pm!(
        user,
        I18n.t("school_engine.pm.semester_title", semester: semester_label),
        I18n.t(
          "school_engine.pm.semester_body",
          semester: semester_label,
          count: posts.size,
          featured_count: featured_count,
          list: list,
        ),
      )
    end

    # 毕业完整时光胶囊
    def self.graduation_capsule!(user, posts)
      list = capsule_lines(posts)
      featured_count = posts.count { |p| p.custom_fields[Featured::CF_FEATURED] == "true" }
      send_capsule_pm!(
        user,
        I18n.t("school_engine.pm.graduation_title"),
        I18n.t(
          "school_engine.pm.graduation_body",
          count: posts.size,
          featured_count: featured_count,
          list: list,
        ),
      )
    end

    def self.capsule_lines(posts)
      posts
        .map do |p|
          "- [#{p.topic&.title}](#{Discourse.base_url}#{p.url})"
        end
        .join("\n")
    end
    private_class_method :capsule_lines

    def self.send_capsule_pm!(user, title, raw)
      return if user.nil?
      PostCreator.create!(
        User.system_user,
        title: title,
        raw: raw,
        archetype: Archetype.private_message,
        target_usernames: user.username,
        skip_validations: true,
      )
    rescue => e
      Rails.logger.warn("school-engine: 时光胶囊私信发送失败 user=#{user&.id}: #{e.message}")
      nil
    end
    private_class_method :send_capsule_pm!
  end
end
