# frozen_string_literal: true

module SchoolEngine
  # 举报 / 审核队列 API（前台举报 + 复核台 + 申诉 + 举报看板）
  class ReportsController < ::ApplicationController
    requires_plugin "school-engine"
    wrap_parameters false

    requires_login
    before_action :ensure_can_review, only: %i[queue detail act reopen board export]
    before_action :ensure_staff_only, only: %i[appeals resolve_appeal]

    # GET /school/report-categories.json —— 举报分类（固定入口用）
    def categories
      render json: { categories: ReportCategories.for_client }
    end

    # POST /school/report.json
    # 固定一键举报入口：分类 + 可选说明 + 可选匿名（后台仍留痕）
    def create
      post = Post.find_by(id: params[:post_id].to_i)
      raise Discourse::NotFound if post.nil?
      raise Discourse::InvalidAccess if post.deleted_at.present?

      category = params[:category].to_s
      raise Discourse::InvalidParameters.new(:category) unless ReportCategories.valid?(category)

      guardian.ensure_can_see!(post)
      raise Discourse::InvalidAccess.new("不能举报自己的帖子") if post.user_id == current_user.id

      # 防刷：每人每小时 20 次举报
      RateLimiter.new(current_user, "school-report:#{current_user.id}", 20, 1.hour).performed!

      anonymous = params[:anonymous].to_s == "true"
      reason = params[:reason].to_s.strip

      # 同一用户对同一帖只记一次（聚合防恶意举报）
      already = Moderation.reporter_ids(post).include?(current_user.id)
      unless already
        Moderation.record_report!(
          post,
          reporter: current_user,
          category: category,
          reason: reason,
          anonymous: anonymous,
        )
        current_user.custom_fields["report_filed_count"] =
          (current_user.custom_fields["report_filed_count"].to_i + 1).to_s
        current_user.save_custom_fields(true)
        Moderation.auto_triage!(post)
      end

      SchoolEngine::Audit.change(
        "report",
        actor: current_user,
        target: post,
        extra: { "category" => category, "anonymous" => anonymous, "duplicate" => already, "has_reason" => reason.present? },
      )
      render json: {
        success: true,
        duplicate: already,
        message: I18n.t("school_engine.report.thanks", minutes: Moderation.sla_minutes_for([category])),
        sla_minutes: Moderation.sla_minutes_for([category]),
      }
    rescue Discourse::InvalidAccess => e
      render json: { errors: [e.message] }, status: :forbidden
    rescue Discourse::InvalidParameters => e
      render json: { errors: [e.message] }, status: :unprocessable_entity
    end

    # GET /school/review.json —— 审核队列（AI 与人工共用）
    def queue
      scope =
        Post
          .joins("JOIN post_custom_fields mcf ON mcf.post_id = posts.id AND mcf.name = 'mod_state'")
          .where("mcf.value IN ('pending','hidden','escalated','folded')")
          .where(deleted_at: nil)
          .order("posts.id DESC")

      if params[:filter].to_s == "overdue"
        # 直接在 SQL 层筛选已逾期且未首次响应的记录，避免逐条 find_by（原为 N+1）
        scope =
          scope
            .joins("JOIN post_custom_fields dl ON dl.post_id = posts.id AND dl.name = 'mod_deadline'")
            .joins(
              "LEFT JOIN post_custom_fields fr ON fr.post_id = posts.id AND fr.name = 'mod_first_response'",
            )
            .where("dl.value < ?", Time.zone.now.iso8601)
            .where("fr.value IS NULL OR fr.value = ''")
            .where("mcf.value NOT IN ('removed','normal')")
          @overdue_filtered = true
      end

      limit = [[params[:limit].to_i.positive? ? params[:limit].to_i : 30, 100].min, 1].max
      offset = [params[:offset].to_i, 0].max
      # count 只查一次，避免原来重复执行
      total = scope.count
      posts = scope.includes(:topic, :user).limit(limit).offset(offset).to_a
      # 批量预取信任等级提示与避嫌所需数据，避免 queue_item 内逐条查库
      preload_queue_hints(posts)

      SchoolEngine::Audit.view("review_queue", actor: current_user, extra: { "filter" => params[:filter].to_s, "total" => total })
      render json: {
        total: total,
        items: posts.map { |p| queue_item(p) },
      }
    end

    # GET /school/review-detail.json?post_id=1
    def detail
      post = Post.find_by(id: params[:post_id].to_i)
      raise Discourse::NotFound if post.nil?
      SchoolEngine::Audit.view("review_detail", actor: current_user, target: post)
      render json: queue_item(post, full: true)
    end

    # POST /school/review-act.json
    # 处置：hint / fold / hide_pending / hide_timed / remove / review / restore / escalate
    def act
      post = Post.find_by(id: params[:post_id].to_i)
      raise Discourse::NotFound if post.nil?

      action = params[:action_code].to_s
      raise Discourse::InvalidParameters.new(:action_code) if action.blank?

      # 避嫌：版主涉本班/本人 → 必须转交
      if Moderation.conflict?(post, current_user) && action != "escalate"
        unless current_user.admin?
          return(
            render json: { errors: [I18n.t("school_engine.report.conflict")], conflict: true },
                   status: :forbidden
          )
        end
      end

      note = params[:note].to_s.strip
      case action
      when "hint"
        Moderation.fold!(post, actor: current_user, note: note)
        Moderation.log_event!(post, "hint", { "by" => current_user.id, "note" => note })
        post.save_custom_fields(true)
      when "fold"
        Moderation.fold!(post, actor: current_user, note: note)
      when "hide_pending"
        Moderation.apply_action!(
          post,
          state: "pending",
          action: "hide_pending",
          actor: current_user,
          note: note,
          minutes: Moderation::TIMED_HIDE_MINUTES,
        )
      when "hide_timed"
        minutes = params[:minutes].to_i
        minutes = Moderation::TIMED_HIDE_MINUTES if minutes <= 0
        Moderation.apply_action!(post, state: "hidden", action: "hide_timed", actor: current_user, note: note, minutes: minutes)
      when "remove"
        Moderation.apply_action!(post, state: "removed", action: "remove", actor: current_user, note: note)
      when "review"
        Moderation.apply_action!(post, state: "escalated", action: "review", actor: current_user, note: note)
      when "restore"
        Moderation.apply_action!(post, state: "normal", action: "restore", actor: current_user, note: note)
      when "escalate"
        post.custom_fields["mod_assignee"] = nil
        Moderation.log_event!(post, "escalated", { "by" => current_user.id, "note" => note })
        post.save_custom_fields(true)
      else
        raise Discourse::InvalidParameters.new(:action_code)
      end

      post.custom_fields["mod_assignee"] = current_user.id
      post.custom_fields["mod_first_response"] ||= Time.zone.now.iso8601
      Moderation.log_event!(post, "handled", { "by" => current_user.id, "note" => note })
      post.save_custom_fields(true)

      state = post.custom_fields["mod_state"].presence || "normal"
      # 通知举报人 + 作者（轻度处置不给作者发"处罚通知"，仅折叠/hint 时提示）
      Moderation.reporter_ids(post).each do |uid|
        Moderation.notify_reporter!(post, reporter: User.find_by(id: uid), state: state, note: note)
      end
      unless %w[folded].include?(state)
        Moderation.notify_author!(post, state: state, note: note)
      end

      SchoolEngine::Audit.change("review_act", actor: current_user, target: post, extra: { "action" => action, "state" => state, "has_note" => note.present? })
      render json: { success: true, state: state }
    end

    # POST /school/review-reopen.json —— 误杀恢复 / 重新打开
    def reopen
      post = Post.find_by(id: params[:post_id].to_i)
      raise Discourse::NotFound if post.nil?
      Moderation.apply_action!(
        post,
        state: "normal",
        action: "restore",
        actor: current_user,
        note: params[:note].to_s.presence || I18n.t("school_engine.report.reopen_note"),
      )
      Moderation.notify_author!(post, state: "normal", note: I18n.t("school_engine.report.reopen_note"))
      render json: { success: true }
    end

    # GET /school/review-board.json —— 举报看板（统计）
    def board
      now = Time.zone.now
      days = params[:days].to_i.clamp(1, 90)
      since = now - days.days

      # 看板统计较重，缓存 30 秒：复核台反复刷新时不会重复全表扫描
      cache_key = "school_engine:board:#{days}"
      payload =
        Rails.cache.fetch(cache_key, expires_in: 30.seconds) do
          # 状态分布：交给数据库聚合，不再把全部记录加载到 Ruby
          states = Hash.new(0)
          PostCustomField
            .where(name: "mod_state")
            .group(:value)
            .count
            .each { |value, count| states[value] += count }

          # 分类分布：近 N 天内的举报
          cats = Hash.new(0)
          PostCustomField
            .where(name: "report_cats")
            .where("updated_at > ?", since)
            .pluck(:value)
            .each do |value|
              value.to_s.split(",").each { |c| cats[c] += 1 unless c.blank? }
            end

          overdue =
            PostCustomField
              .where(name: "mod_deadline")
              .where("value < ?", now.iso8601)
              .count
          ai_flagged =
            PostCustomField.where(name: "ai_action").where.not(value: %w[none]).count

          {
            states: states,
            categories:
              cats
                .sort_by { |_, v| -v }
                .map { |k, v| { code: k, label: ReportCategories.label(k), count: v } },
            overdue: overdue,
            ai_flagged: ai_flagged,
            sla_minutes: Moderation::SLA_MINUTES,
          }
        end

      SchoolEngine::Audit.view("review_board", actor: current_user, extra: { "days" => days })
      render json: payload.merge(generated_at: now.iso8601)
    end

    # GET /school/review-export.csv —— 审核日志导出（staff）
    def export
      require "csv"
      posts =
        Post
          .joins("JOIN post_custom_fields ecf ON ecf.post_id = posts.id AND ecf.name = 'mod_state'")
          .where(deleted_at: nil)
          .order(id: :desc)
          .limit(2000)

      csv =
        CSV.generate do |out|
          out << %w[post_id topic 作者 状态 分类 AI分数 AI建议 举报人 初始截止 首次响应 事件]
          posts.each do |p|
            out << [
              p.id,
              p.topic&.title,
              p.user&.username,
              p.custom_fields["mod_state"],
              p.custom_fields["report_cats"],
              p.custom_fields["ai_score"],
              p.custom_fields["ai_action"],
              Moderation.reporter_ids(p).join(" "),
              p.custom_fields["mod_deadline"],
              p.custom_fields["mod_first_response"],
              JSON.generate(Moderation.events(p)),
            ]
          end
        end
      SchoolEngine::Audit.change("audit_export", actor: current_user)
      send_data csv, filename: "审核日志-#{Time.current.strftime("%Y%m%d")}.csv", type: "text/csv; charset=utf-8"
    end

    # GET /school/appeals.json —— 申诉列表（staff 处理）
    def appeals
      rows =
        UserCustomField
          .where(name: "appeal_state")
          .where(value: %w[pending])
          .order(updated_at: :desc)
          .limit(200)
          .map do |cf|
            u = User.find_by(id: cf.user_id)
            {
              user_id: cf.user_id,
              username: u&.username,
              post_id: u&.custom_fields&.[]("appeal_post_id"),
              body: u&.custom_fields&.[]("appeal_body"),
              at: u&.custom_fields&.[]("appeal_at"),
            }
          end
      render json: { appeals: rows }
    end

    # POST /school/appeal.json —— 用户申诉（针对被处置的帖子）
    def appeal
      post = Post.find_by(id: params[:post_id].to_i)
      raise Discourse::NotFound if post.nil?
      raise Discourse::InvalidAccess unless post.user_id == current_user.id

      RateLimiter.new(current_user, "school-appeal:#{current_user.id}", 5, 1.day).performed!

      body = params[:body].to_s.strip
      raise Discourse::InvalidParameters.new(:body) if body.length < 5

      # 已有待处理申诉时不允许重复提交（避免刷复核台）
      if current_user.custom_fields["appeal_state"] == "pending" &&
         current_user.custom_fields["appeal_post_id"].to_s == post.id.to_s
        return render json: { success: true, duplicate: true, message: I18n.t("school_engine.report.appeal_pending") }
      end
      # 同一帖已申诉成功过则无需再申
      if current_user.custom_fields["appeal_state"] == "uphold" &&
         current_user.custom_fields["appeal_post_id"].to_s == post.id.to_s
        return(
          render json: { errors: [I18n.t("school_engine.report.appeal_already_uphold")] },
                 status: :unprocessable_entity
        )
      end

      current_user.custom_fields["appeal_state"] = "pending"
      current_user.custom_fields["appeal_post_id"] = post.id.to_s
      current_user.custom_fields["appeal_body"] = body.truncate(1000)
      current_user.custom_fields["appeal_at"] = Time.zone.now.iso8601
      current_user.save_custom_fields(true)

      Moderation.log_event!(post, "appeal", { "by" => current_user.id })
      post.save_custom_fields(true)

      SchoolEngine::Audit.change("appeal", actor: current_user, target: post)
      render json: { success: true, message: I18n.t("school_engine.report.appeal_received") }
    end

    # POST /school/resolve-appeal.json —— staff 处理申诉
    def resolve_appeal
      user = User.find_by(id: params[:user_id].to_i)
      raise Discourse::NotFound if user.nil?

      result = params[:result].to_s
      note = params[:note].to_s.strip
      unless %w[uphold reject].include?(result)
        raise Discourse::InvalidParameters.new(:result)
      end

      post = Post.find_by(id: user.custom_fields["appeal_post_id"].to_i)
      if result == "uphold"
        user.custom_fields["appeal_state"] = "uphold"
        if post
          Moderation.apply_action!(post, state: "normal", action: "uphold_appeal", actor: current_user, note: note)
          Moderation.log_event!(post, "appeal_uphold", { "by" => current_user.id, "note" => note })
          post.save_custom_fields(true)
        end
        Moderation.notify(user, "appeal_uphold", topic_title: post&.topic&.title.to_s, note: note)
      else
        user.custom_fields["appeal_state"] = "reject"
        if post
          Moderation.log_event!(post, "appeal_reject", { "by" => current_user.id, "note" => note })
          post.save_custom_fields(true)
        end
        Moderation.notify(user, "appeal_reject", topic_title: post&.topic&.title.to_s, note: note)
      end
      user.save_custom_fields(true)

      SchoolEngine::Audit.change("resolve_appeal", actor: current_user, target: post, extra: { "result" => result, "user_id" => user.id })
      render json: { success: true }
    end

    private

    # 批量预取：一次查询拿到所有相关举报人的信任等级、以及当前用户的班级圈，
    # 避免 queue_item 中对每条帖子分别查库（原为 O(n) 次查询）。
    def preload_queue_hints(posts)
      return if posts.empty?

      post_ids = posts.map(&:id)

      # 1) 信任等级提示：帖子 -> 举报人 user_id 列表
      report_rows =
        PostCustomField.where(name: "report_ids", post_id: post_ids).pluck(:post_id, :value)
      reporter_map = {}
      report_rows.each do |pid, val|
        ids = val.to_s.split(",").reject(&:blank?).map(&:to_i)
        reporter_map[pid] = ids if ids.any?
      end

      all_reporter_ids = reporter_map.values.flatten.uniq
      trust_by_user =
        User.where(id: all_reporter_ids).pluck(:id, :trust_level).to_h

      @trust_hints = {}
      reporter_map.each do |pid, ids|
        levels = ids.filter_map { |uid| trust_by_user[uid] }
        @trust_hints[pid] = levels.max if levels.any?
      end

      # 2) 避嫌判定：预先算好当前用户的班级圈
      @conflicts = {}
      return if current_user.nil? || current_user.admin?

      my_groups =
        current_user.groups.where("name LIKE 'xx-%' OR name LIKE 'cz-%'").pluck(:name)
      if my_groups.empty?
        posts.each { |p| @conflicts[p.id] = false }
        return
      end

      author_ids = posts.map(&:user_id).compact.uniq
      if author_ids.any?
        author_groups =
          GroupUser
            .joins(:group)
            .where(user_id: author_ids)
            .where("groups.name LIKE 'xx-%' OR groups.name LIKE 'cz-%'")
            .pluck(:user_id, "groups.name")
        groups_by_author = Hash.new { |h, k| h[k] = [] }
        author_groups.each { |uid, gname| groups_by_author[uid] << gname }
      else
        groups_by_author = {}
      end

      posts.each do |p|
        @conflicts[p.id] =
          if p.user_id == current_user.id
            true
          else
            (my_groups & Array(groups_by_author[p.user_id])).any?
          end
      end
    end

    def ensure_can_review
      return if current_user&.staff?
      group_name = SiteSetting.school_engine_moderation_group.to_s.strip
      return if group_name.present? && current_user.in_any_groups?(Group.where(name: group_name).select(:id))
      raise Discourse::InvalidAccess.new
    end

    def ensure_staff_only
      guardian.ensure_is_staff!
    end

    def queue_item(post, full: false)
      author = post.user
      data = {
        post_id: post.id,
        topic_id: post.topic_id,
        topic_title: post.topic&.title,
        post_number: post.post_number,
        url: post.url,
        author: author&.username,
        author_id: author&.id,
        author_class: SchoolEngine::Grade.display_class(author),
        excerpt: self.class.helpers.strip_tags(post.cooked.to_s).gsub(/\s+/, " ").strip.truncate(160),
        state: post.custom_fields["mod_state"].presence || "normal",
        categories: post.custom_fields["report_cats"].to_s.split(",").map { |c| { code: c, label: ReportCategories.label(c) } },
        report_count: post.custom_fields["report_count"].to_i,
        anonymous_reports: Moderation.events(post).count { |e| e["kind"] == "reported" && e["by"] == "anonymous" },
        reporter_weight: Moderation.reporter_weight(post),
        trust_hint: @trust_hints&.fetch(post.id, nil) || Moderation.trust_hint(post),
        ai: {
          state: post.custom_fields["ai_state"],
          score: post.custom_fields["ai_score"],
          action: post.custom_fields["ai_action"],
          cats: post.custom_fields["ai_cats"].to_s.split(","),
        },
        deadline: post.custom_fields["mod_deadline"],
        overdue: Moderation.overdue?(post),
        first_response: post.custom_fields["mod_first_response"],
        assignee: post.custom_fields["mod_assignee"],
        expires_at: post.custom_fields["mod_expires_at"],
        conflict: @conflicts&.fetch(post.id, false) || Moderation.conflict?(post, current_user),
      }
      if full
        data[:raw] = post.raw
        data[:events] = Moderation.events(post).reverse
        data[:deleted] = post.deleted_at.present?
        data[:hidden] = post.hidden?
      end
      data
    end
  end
end
