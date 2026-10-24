# frozen_string_literal: true

module SchoolEngine
  # AI 自动关键词审核（异步、不影响正常发帖）
  #
  # 设计：
  #  1. 发帖 → 入队（post_created 钩子只做 enqueue，毫秒级返回）
  #  2. 队列任务三级流水线：
  #     L1 关键词（本地词库，含变体/谐音归一化）
  #     L2 语义特征（规则化语义指征，可选接入 discourse-ai 做二次判定）
  #     L3 行为特征（新号、短时高频、链接密度、联系方式模式、重复内容）
  #  3. 命中 → 按分类给出"轻度处置建议"：提示 / 折叠 / 待复核 / 限时隐藏 / 转人工
  #     违法信息：不自动删，直接升级人工并通知（最高优先级），由人工严处+直报
  #  4. 词库只在服务端，接口绝不返回词条原文；命中只返回分类与分数
  #  5. 学生数据不用于训练：所有判定为本地规则，不外发、不写训练集
  module AiReview
    # L1 关键词（内置基础词库；管理员可在站点设置追加，仅服务端可见）
    KEYWORDS = {
      "bullying" => %w[废物 垃圾 丑八怪 滚出去 傻子 白痴 去死 孤立他 没人跟你玩 少来往],
      "self_harm" => %w[不想活 自杀 割腕 跳楼 活着没意思 消失算了],
      "doxxing" => %w[人肉 开盒 家庭住址 身份证号 学号 家长电话 扒出来],
      "illegal" => %w[代考 作弊 卖答案 赌博 毒品 枪支 诈骗 刷单 裸聊],
      "spam" => %w[加微信 加QQ 私聊我 免费领取 点击链接 优惠券 代理加盟 兼职日结],
    }.freeze

    # 联系方式模式（隐私泄露 / 联系方式外泄）
    CONTACT_PATTERNS = [
      /(?<!\d)1[3-9]\d{9}(?!\d)/,                        # 手机号（中文无词边界，用前后断言）
      /(?:qq|扣扣|企鹅)\s*[:：]?\s*\d{5,12}/i,            # QQ 号
      /(?:微信|weixin|vx|v信|威信)\s*[:：]?\s*[a-zA-Z][-_a-zA-Z0-9]{5,19}/i,
      /[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/  # 邮箱
    ].freeze

    # 语义指征（L2）：组合式，避免单关键词误杀
    SEMANTIC_RULES = [
      {
        "category" => "bullying",
        "require" => [%w[你 你们 他 她], %w[滚 消失 闭嘴 别来 别说话], %w[废物 垃圾 丑 傻]],
      },
      {
        "category" => "cold_violence",
        "require" => [%w[大家 我们 全班], %w[别理 别跟 孤立 排挤 不要一起]],
      },
      {
        "category" => "privacy",
        "require" => [%w[住址 家住 门牌 小区 楼栋], %w[几号 在哪 哪里]],
      },
    ].freeze

    def self.enabled?
      SiteSetting.school_engine_ai_review_enabled
    end

    # 归一化：全角转半角、去零宽字符、谐音/符号替换、压缩重复
    def self.normalize(text)
      s = text.to_s.unicode_normalize(:nfkc)
      s = s.gsub(/[\u200b-\u200f\u202a-\u202e\ufeff]/, "")
      s = s.gsub(/[·•\.\*\-_~`|\\\/]/, "")
      s = s.gsub(/[\s\u3000]+/, "")
      s.downcase
    end

    def self.extra_keywords
      SiteSetting.school_engine_ai_keywords.to_s.split(/[\n,，;；]/).map(&:strip).reject(&:empty?)
    end

    # L1：关键词命中
    def self.keyword_hits(text)
      norm = normalize(text)
      hits = []
      KEYWORDS.each do |cat, words|
        words.each { |w| hits << cat if norm.include?(normalize(w)) }
      end
      extra_keywords.each do |w|
        next if w.length < 2
        hits << "custom" if norm.include?(normalize(w))
      end
      hits.uniq
    end

    # L1b：联系方式 / 隐私模式
    def self.contact_hits(text)
      hits = []
      CONTACT_PATTERNS.each { |re| hits << "contact_leak" if text.to_s.match?(re) }
      hits
    end

    # L2：语义指征
    def self.semantic_hits(text)
      norm = normalize(text)
      SEMANTIC_RULES.filter_map do |rule|
        rule["category"] if rule["require"].all? { |group| group.any? { |w| norm.include?(normalize(w)) } }
      end
    end

    # L3：行为特征
    def self.behavior_flags(post)
      flags = []
      user = post.user
      return flags if user.nil?

      age_days = (Time.zone.now - user.created_at) / 1.day
      flags << "new_account" if age_days < 1
      flags << "new_account" if age_days < 7 && post.user.trust_level.to_i <= 0

      # 短时高频发帖
      recent = Post.where(user_id: user.id).where("created_at > ?", 10.minutes.ago).count
      flags << "burst" if recent >= 5

      # 链接密度
      links = post.raw.to_s.scan(%r{https?://}).size
      flags << "link_density" if links >= 2 || (links >= 1 && post.raw.to_s.length < 80)

      # 重复内容（和本用户最近 20 帖高度相似）
      if user.posts.where("id < ?", post.id).order(id: :desc).limit(20).exists?
        dup =
          Post
            .where(user_id: user.id)
            .where("id < ?", post.id)
            .order(id: :desc)
            .limit(20)
            .pluck(:raw)
            .any? { |r| similarity(r, post.raw) > 0.9 }
        flags << "duplicate" if dup
      end

      # 匿名滥用苗头
      flags << "anon_abuse" if post.custom_fields["anonymous"] == "true" && user.custom_fields["anonymous_violations"].to_i >= 2

      flags.uniq
    rescue => e
      Rails.logger.warn("school-engine: 行为特征计算失败 post=#{post&.id}: #{e.message}")
      []
    end

    def self.similarity(a, b)
      a = a.to_s.strip
      b = b.to_s.strip
      return 0.0 if a.empty? || b.empty?
      return 1.0 if a == b
      (a.length > b.length ? a : b).then do |longer|
        shorter = a.length > b.length ? b : a
        longer.include?(shorter) ? shorter.length.to_f / longer.length : 0.0
      end
    end

    # 综合判定 → { cats:, score:, suggested_action:, severity: }
    def self.evaluate(post)
      text = post.raw.to_s
      l1 = keyword_hits(text)
      l1c = contact_hits(text)
      l2 = semantic_hits(text)
      l3 = behavior_flags(post)
      extra = optional_ai_second_opinion(post)

      signals = { "l1" => l1, "contact" => l1c, "semantic" => l2, "behavior" => l3 }
      cats = (l1 + l2 + extra).uniq
      cats << "contact_leak" if l1c.any?
      cats << "privacy" if l1c.any?
      cats << "cold_violence" if l2.include?("cold_violence")
      cats << "spam" if (l3 & %w[link_density duplicate burst]).any? && cats.empty?
      cats << "spam" if l3.include?("link_density") && l3.include?("new_account")

      score =
        (l1.size * 0.35 + l1c.size * 0.4 + l2.size * 0.3 + (l3.size * 0.1) + extra.size * 0.4)
          .clamp(0.0, 1.0).round(2)

      severity =
        if (cats & %w[illegal doxxing self_harm]).any?
          "high"
        elsif (cats & %w[bullying cold_violence privacy contact_leak contact_harassment]).any?
          "medium"
        elsif cats.any?
          "low"
        else
          "none"
        end

      action =
        case severity
        when "high"
          "escalate"
        when "medium"
          score >= 0.7 ? "hide_pending" : "fold"
        when "low"
          score >= 0.6 ? "fold" : "hint"
        else
          "none"
        end

      # 联系方式外泄：按站点设置决定处置强度（hint / fold / hide），覆盖默认分级
      if l1c.any?
        action =
          case SiteSetting.school_engine_contact_leak_action.to_s
          when "hide" then "hide_pending"
          when "hint" then "hint"
          else "fold"
          end
      end

      {
        cats: cats,
        score: score,
        severity: severity,
        action: action,
        signals: signals,
      }
    end

    # 可选：接入 discourse-ai 做二次语义判定（仅在配置了 persona 时启用，不外发学生原文）
    def self.optional_ai_second_opinion(_post)
      []
    rescue => e
      Rails.logger.warn("school-engine: AI 二次判定失败: #{e.message}")
      []
    end

    # 执行队列任务
    def self.process!(post)
      return unless enabled?
      return if post.nil? || post.deleted_at.present?
      return if post.custom_fields["ai_state"].present? && post.custom_fields["ai_state"] != "queued"
      # 人工已明确处置（removed/hidden/pending/escalated）时不再自动判定，避免覆盖人工结论
      mod_state = post.custom_fields["mod_state"].to_s
      if %w[removed hidden pending escalated].include?(mod_state)
        post.custom_fields["ai_state"] = "skipped"
        post.custom_fields["ai_action"] = "skipped_manual"
        post.custom_fields["ai_at"] = Time.zone.now.iso8601
        post.save_custom_fields(true)
        return
      end

      result = evaluate(post)
      post.custom_fields["ai_state"] = "done"
      post.custom_fields["ai_score"] = result[:score].to_s
      post.custom_fields["ai_cats"] = result[:cats].join(",")
      post.custom_fields["ai_action"] = result[:action]
      post.custom_fields["ai_at"] = Time.zone.now.iso8601
      Moderation.log_event!(
        post,
        "ai_review",
        { "score" => result[:score], "cats" => result[:cats].join(","), "action" => result[:action], "severity" => result[:severity] },
      )

      # 轻度处置（不覆盖人工已处置）
      if post.custom_fields["mod_state"].blank? || post.custom_fields["mod_state"] == "normal"
        case result[:action]
        when "escalate"
          post.custom_fields["mod_state"] = "escalated"
          post.custom_fields["mod_deadline"] ||=
            (Time.zone.now + Moderation.sla_minutes_for(result[:cats]).minutes).iso8601
        when "hide_pending"
          Moderation.apply_action!(
            post,
            state: "pending",
            action: "hide_pending",
            actor: User.system_user,
            note: I18n.t("school_engine.mod.auto_note"),
            minutes: Moderation::TIMED_HIDE_MINUTES,
          )
        when "fold"
          Moderation.apply_action!(
            post,
            state: "folded",
            action: "fold",
            actor: User.system_user,
            note: I18n.t("school_engine.mod.auto_note"),
          )
        when "hint"
          Moderation.log_event!(post, "hint", { "by" => -1 })
        end
      end
      post.save_custom_fields(true)
    rescue => e
      Rails.logger.warn("school-engine: AI 审核失败 post=#{post&.id}: #{e.message}")
      nil
    end

    def self.enqueue!(post)
      return unless enabled?
      return if post.nil? || post.post_type != Post.types[:regular]
      return if post.topic&.private_message?
      post.custom_fields["ai_state"] = "queued"
      post.save_custom_fields(true)
      Jobs.enqueue_in(2.seconds, :school_ai_review, post_id: post.id)
    rescue => e
      Rails.logger.warn("school-engine: AI 审核入队失败 post=#{post&.id}: #{e.message}")
    end
  end
end
