# frozen_string_literal: true

module SchoolEngine
  # 举报 / 审核队列核心（与 AI 审核共用同一队列）
  #
  # 数据落地全部使用 custom fields，避免额外迁移：
  #  - 帖子：report_count / report_cats / report_ids / mod_state / mod_events /
  #          mod_action / mod_action_at / mod_action_by / mod_assignee / mod_deadline /
  #          mod_first_response / ai_state / ai_cats / ai_score / ai_action / ai_at
  #  - 用户：report_filed_count / report_abuse_count / appeal_state / appeal_body / ...
  module Moderation
    # 帖子处置状态机
    #  normal      正常
    #  folded      折叠（仍可见，需点击展开）
    #  pending     待复核（对普通用户不可见，仅 staff 与作者可见）
    #  hidden      限时隐藏（pending 的定时版本，到期自动恢复）
    #  removed     下架（仅 staff 可见）
    #  escalated   转人工（进入人工队列，不自动处置）
    STATES = %w[normal folded pending hidden removed escalated].freeze

    # 动作码
    ACTIONS = %w[
      hint fold hide_pending hide_timed review remove support escalate report_author
      restore uphold_appeal reject_appeal
    ].freeze

    SLA_MINUTES = {
      "illegal" => 60,
      "doxxing" => 60,
      "self_harm" => 60,
      "bullying" => 240,
      "contact_harassment" => 240,
      "privacy" => 240,
      "anon_abuse" => 1440,
      "spam" => 1440,
    }.freeze
    DEFAULT_SLA_MINUTES = 1440

    # 限时隐藏时长（分钟）
    TIMED_HIDE_MINUTES = 24 * 60

    def self.sla_minutes_for(cats)
      (Array(cats) & SLA_MINUTES.keys).map { |c| SLA_MINUTES[c] }.min || DEFAULT_SLA_MINUTES
    end

    # 安全解析 ISO 时间，非法值返回 nil（避免定时任务整批崩溃）
    def self.parse_time(value)
      return nil if value.blank?
      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    # ---- 事件日志（审核日志，双方留痕，前台可见"处理过程"）----
    def self.log_event!(post, kind, payload = {})
      return unless post
      events = JSON.parse(post.custom_fields["mod_events"].presence || "[]") rescue []
      events = [] unless events.is_a?(Array)
      events << { "at" => Time.zone.now.iso8601, "kind" => kind }.merge(payload.stringify_keys)
      events = events.last(120)
      post.custom_fields["mod_events"] = JSON.generate(events)
    end

    def self.events(post)
      list = JSON.parse(post.custom_fields["mod_events"].presence || "[]") rescue []
      list.is_a?(Array) ? list : []
    end

    # ---- 举报入库 ----
    def self.record_report!(post, reporter:, category:, reason:, anonymous: false)
      cats = Array(post.custom_fields["report_cats"].to_s.split(",")).reject(&:blank?)
      cats << category unless cats.include?(category)
      ids = Array(post.custom_fields["report_ids"].to_s.split(",")).reject(&:blank?)
      ids << reporter.id.to_s unless ids.include?(reporter.id.to_s)

      post.custom_fields["report_cats"] = cats.join(",")
      post.custom_fields["report_ids"] = ids.join(",")
      post.custom_fields["report_count"] = ids.size.to_s
      post.custom_fields["report_last_at"] = Time.zone.now.iso8601
      post.custom_fields["mod_deadline"] ||=
        (Time.zone.now + sla_minutes_for(cats).minutes).iso8601
      post.custom_fields["mod_state"] ||= "pending"
      unless %w[removed hidden folded].include?(post.custom_fields["mod_state"])
        post.custom_fields["mod_state"] = "pending"
      end

      log_event!(
        post,
        "reported",
        {
          "by" => anonymous ? "anonymous" : reporter.id,
          "category" => category,
          "reason" => reason.to_s.truncate(500),
        },
      )
      post.save_custom_fields(true)
    end

    # ---- 处置 ----
    def self.apply_action!(post, state:, action:, actor:, note: nil, minutes: nil)
      unless STATES.include?(state)
        raise Discourse::InvalidParameters.new(:state)
      end

      now = Time.zone.now
      prev = post.custom_fields["mod_state"].presence || "normal"
      post.custom_fields["mod_state"] = state
      post.custom_fields["mod_action"] = action.to_s
      post.custom_fields["mod_action_at"] = now.iso8601
      post.custom_fields["mod_action_by"] = actor&.id
      post.custom_fields["mod_prev_state"] = prev
      post.custom_fields["mod_first_response"] ||= now.iso8601
      if minutes.present?
        post.custom_fields["mod_expires_at"] = (now + minutes.to_i.minutes).iso8601
      else
        post.custom_fields.delete("mod_expires_at")
      end

      log_event!(
        post,
        "action",
        {
          "by" => actor&.id,
          "state" => state,
          "action" => action.to_s,
          "note" => note.to_s.truncate(500),
          "expires_at" => post.custom_fields["mod_expires_at"],
        },
      )
      post.save_custom_fields(true)

      # 可见性同步（核心 hidden 标记 + 插件自有掩码）：失败必须抛出，不能静默
      unless sync_visibility!(post)
        raise Discourse::InvalidAccess.new("可见性同步失败，请重试")
      end
      post
    end

    # pending/hidden/removed 走核心 hidden（对普通用户与列表不可见）；folded 仅前端折叠
    def self.sync_visibility!(post)
      state = post.custom_fields["mod_state"].presence || "normal"
      should_hide = %w[hidden removed pending].include?(state)

      if should_hide
        unless post.hidden?
          post.hidden = true
          post.hidden_at = Time.zone.now
          post.skip_validation = true
          post.save!(validate: false)
        end
      elsif state == "normal"
        if post.hidden?
          post.hidden = false
          post.hidden_at = nil
          post.hidden_reason_id = nil
          post.skip_validation = true
          post.save!(validate: false)
        end
      end
      post.custom_fields["mod_visible"] = should_hide ? "false" : "true"
      post.save_custom_fields(true)
      true
    rescue => e
      Rails.logger.error("school-engine: 审核可见性同步失败 post=#{post&.id}: #{e.class}: #{e.message}")
      false
    end

    # 折叠：仅做展示层折叠，不隐藏
    def self.fold!(post, actor:, note: nil)
      apply_action!(post, state: "folded", action: "fold", actor: actor, note: note)
    end

    # ---- 按分类自动初判（举报驱动）----
    def self.auto_triage!(post)
      cats = post.custom_fields["report_cats"].to_s.split(",")
      return if cats.empty?
      if post.custom_fields["ai_state"].blank?
        post.custom_fields["ai_state"] = "skipped"
        post.custom_fields["ai_action"] = "none"
        post.custom_fields["ai_at"] = Time.zone.now.iso8601
        post.custom_fields["ai_cats"] = cats.join(",")
      end

      # 违法 / 人肉 / 自伤：不自动删除，直接升级人工并给最短 SLA
      if (cats & %w[illegal doxxing self_harm]).any?
        post.custom_fields["mod_state"] = "escalated"
        post.custom_fields["mod_assignee"] = nil
        log_event!(post, "escalated", { "reason" => "high_risk_category", "by" => -1 })
        post.save_custom_fields(true)
        notify_staff_high_risk!(post, cats)
        return
      end

      # 欺凌 / 隐私 / 联系方式骚扰：先隐藏待复核，保护当事人
      if (cats & %w[bullying privacy contact_harassment]).any? && post.custom_fields["mod_state"].blank?
        apply_action!(
          post,
          state: "pending",
          action: "hide_pending",
          actor: User.system_user,
          note: "保护性隐藏，待人工复核",
          minutes: TIMED_HIDE_MINUTES,
        )
        log_event!(post, "auto_protect", { "by" => -1, "category" => (cats & %w[bullying privacy contact_harassment]).join(",") })
        post.save_custom_fields(true)
      end
    end

    # ---- SLA 逾期 ----
    def self.overdue?(post)
      deadline = post.custom_fields["mod_deadline"]
      return false if deadline.blank?
      return false if post.custom_fields["mod_first_response"].present?
      return false if %w[removed normal].include?(post.custom_fields["mod_state"])
      parsed = begin
        Time.zone.parse(deadline.to_s)
      rescue ArgumentError, TypeError
        nil
      end
      return false if parsed.nil?
      Time.zone.now > parsed
    end

    # ---- 避嫌（版主涉及本班 / 本人 / 朋友 → 转交）----
    # 返回 true 表示存在利益冲突，应转交他人处理
    def self.conflict?(post, user)
      return false if user.nil?
      return false if user.admin? # 管理员不参与避嫌，可兜底

      # 本人或自己发的帖子
      return true if post.user_id == user.id

      # 同一班级圈（班级相关冲突）
      my_groups = user.groups.where("name LIKE 'xx-%' OR name LIKE 'cz-%'").pluck(:name)
      return false if my_groups.empty?
      author_groups = post.user.groups.where("name LIKE 'xx-%' OR name LIKE 'cz-%'").pluck(:name)
      (my_groups & author_groups).any?
    rescue => e
      Rails.logger.warn("school-engine: 避嫌判定失败 post=#{post&.id}: #{e.message}")
      false
    end

    # ---- 举报人保护：匿名举报后台留痕 ----
    def self.reporter_ids(post)
      post.custom_fields["report_ids"].to_s.split(",").reject(&:blank?).map(&:to_i)
    end

    # 聚合防恶意举报：同一用户反复举报同一作者 / 同一帖 → 降权（不丢弃，仅提示）
    def self.reporter_weight(post)
      count = post.custom_fields["report_count"].to_i
      return "low" if count <= 1
      return "normal" if count <= 3
      "aggregated"
    end

    # 信任等级加权只作参考（不决定处置，仅排队时提示）
    def self.trust_hint(post)
      ids = reporter_ids(post)
      return nil if ids.empty?
      levels = User.where(id: ids).pluck(:trust_level).compact
      return nil if levels.empty?
      levels.max
    end

    # ---- 通知 ----
    def self.notify(user, title_key, body_vars = {})
      return if user.nil? || user.id.negative?
      PostCreator.create!(
        User.system_user,
        title: I18n.t("school_engine.pm.#{title_key}_title"),
        raw: I18n.t("school_engine.pm.#{title_key}_body", body_vars),
        archetype: Archetype.private_message,
        target_usernames: user.username,
        skip_validations: true,
      )
    rescue => e
      Rails.logger.warn("school-engine: 审核通知发送失败 user=#{user&.id}: #{e.message}")
      nil
    end

    def self.notify_reporter!(post, reporter:, state:, note: nil)
      return if reporter.nil? || reporter.id.negative?
      link = "#{Discourse.base_url}#{post.url}"
      notify(
        reporter,
        "report_result",
        topic_title: post.topic&.title.to_s,
        url: link,
        state: I18n.t("school_engine.report.states.#{state}", default: state.to_s),
        note: note.to_s,
      )
    end

    def self.notify_author!(post, state:, note: nil)
      author = post.user
      return if author.nil? || author.id.negative?
      notify(
        author,
        "moderation_result",
        topic_title: post.topic&.title.to_s,
        url: "#{Discourse.base_url}#{post.url}",
        state: I18n.t("school_engine.report.states.#{state}", default: state.to_s),
        note: note.to_s,
      )
    end

    def self.notify_staff_high_risk!(post, cats)
      Group.find_by(name: SiteSetting.school_engine_moderation_group.to_s.presence || "moderators")
      target = Group.where(name: [SiteSetting.school_engine_moderation_group.to_s, "moderators"].uniq).first
      return unless target
      GroupUser.where(group_id: target.id).includes(:user).each do |gu|
        notify(
          gu.user,
          "high_risk_report",
          topic_title: post.topic&.title.to_s,
          url: "#{Discourse.base_url}/school/review",
          categories: cats.map { |c| ReportCategories.label(c) }.join("、"),
        )
      end
    rescue => e
      Rails.logger.warn("school-engine: 高风险通知失败: #{e.message}")
    end
  end
end
