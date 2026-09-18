# frozen_string_literal: true

# 自定义首页（服务端渲染，非 Ember 壳）：今日话题 + 当日精选回帖
# 路由经 Discourse::Application.routes.prepend 接管 "/"，原生列表移至 /latest
class SchoolEngineHomeController < ::ApplicationController
  requires_plugin "school-engine"

  # 站点开启 login_required 时，由本控制器自行重定向到自定义登录页（不走 Ember 登录）
  skip_before_action :redirect_to_login_if_required, only: :index
  before_action :redirect_to_school_login, only: :index
  layout "school_engine_home/layout"

  # GET /
  def index
    @topic = daily_topic
    @featured = featured_posts
  end

  private

  def redirect_to_school_login
    redirect_to "/school/login" if SiteSetting.login_required? && current_user.nil?
  end

  def expression_category
    @expression_category ||= SchoolEngine::Expression.category
  end

  # 排除学生标记"不给老师看"的主题（首页面向包括教师的所有人）
  def hidden_from_staff_sql
    <<~SQL.squish
      SELECT p.topic_id
      FROM posts p
      JOIN post_custom_fields pcf ON pcf.post_id = p.id
      WHERE p.post_number = 1 AND pcf.name = 'hide_from_staff' AND pcf.value = 'true'
    SQL
  end

  def expression_topics
    return Topic.none unless expression_category
    Topic
      .where(category_id: expression_category.id, deleted_at: nil, archived: false, visible: true)
      .where("topics.id NOT IN (#{hidden_from_staff_sql})")
  end

  # 今日话题：topic cf daily_topic=今日（预留）→ 表达空间 staff 创建的最新主题
  def daily_topic
    topic =
      expression_topics.where(
        id:
          TopicCustomField.where(
            name: "daily_topic",
            value: Date.today.iso8601,
          ).select(:topic_id),
      ).order(created_at: :desc).first
    topic ||=
      expression_topics
        .where(user_id: User.where("admin = TRUE OR moderator = TRUE"))
        .order(created_at: :desc)
        .first
    return nil unless topic

    op = topic.first_post
    {
      title: topic.title,
      url: topic.relative_url,
      excerpt: op ? excerpt_html(op.cooked, 220) : "",
      created_at: topic.created_at,
    }
  end

  # 当日精选；当天没有则回退最近一批精选（首页永不空壳）
  def featured_posts
    limit = [SiteSetting.school_engine_featured_per_day.to_i, 1].max
    now = Time.zone.now
    start_iso = now.beginning_of_day.utc.iso8601
    finish_iso = now.end_of_day.utc.iso8601

    base =
      Post
        .joins(:topic)
        .joins(
          "JOIN post_custom_fields school_pcf_featured ON school_pcf_featured.post_id = posts.id AND school_pcf_featured.name = 'school_featured'",
        )
        .joins(
          "JOIN post_custom_fields school_pcf_at ON school_pcf_at.post_id = posts.id AND school_pcf_at.name = 'school_featured_at'",
        )
        .where(topic_id: expression_topics.select(:id))
        .where(hidden: false, deleted_at: nil, post_type: Post.types[:regular])
        .where("posts.post_number > 1")

    posts =
      base
        .where("school_pcf_at.value >= ? AND school_pcf_at.value < ?", start_iso, finish_iso)
        .order("school_pcf_at.value DESC")
        .limit(limit)
        .to_a
    if posts.empty?
      @fallback = true
      posts = base.order("school_pcf_at.value DESC").limit(limit).to_a
    else
      @fallback = false
    end

    posts.map { |post| present_featured(post) }
  end

  def present_featured(post)
    anon = post.custom_fields["anonymous"] == "true"
    {
      url: post.url,
      excerpt: excerpt_html(post.cooked, 200),
      like_count: post.like_count,
      anonymous: anon,
      author_name: anon ? SchoolEngine::Anonymous.display_name_for(post) : post.user&.username,
      username: anon ? nil : post.user&.username,
    }
  end

  def excerpt_html(cooked, length)
    text = self.class.helpers.strip_tags(cooked.to_s).gsub(/\s+/, " ").strip
    text = CGI.unescapeHTML(text)
    text.truncate(length)
  end
end
