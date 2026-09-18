# frozen_string_literal: true

# name: school-engine
# about: 校园社区学制引擎：年级计算、班级圈自动创建与权限、毕业标记、小升初选班、匿名表白墙、同学录
# version: 0.2.0
# authors: cpt110412
# url: https://github.com/cpt110412/school-engine
# required_version: 3.2.0

enabled_site_setting :school_engine_enabled

register_locale :zh_CN

register_asset "stylesheets/school-engine.scss"

register_svg_icon "address-book"
register_svg_icon "user-group"

module ::SchoolEngine
  PLUGIN_NAME = "school-engine"
end

require_relative "lib/school_engine/engine"

after_initialize do
  # "不给老师看"开关：前端 composer.schoolHideFromStaff → 发新主题请求参数 school_hide_from_staff
  # （参照 discourse-post-voting 的 serializeOnCreate + add_permitted_post_create_param 模式；
  #   服务端在 post_created 钩子校验创建者身份后才落 post custom field；
  #   必须在 after_initialize 内调用：该 API 引用 Post 模型，激活阶段模型尚未加载）
  add_permitted_post_create_param(:school_hide_from_staff)
  # 表达空间回帖级匿名：前端 composer.schoolAnonymous → school_anonymous 参数
  add_permitted_post_create_param(:school_anonymous)
  # 班级通知：staff 在班级圈发主题 → school_class_notice 参数
  add_permitted_post_create_param(:school_class_notice)

  require_relative "lib/school_engine/grade"
  require_relative "lib/school_engine/pinyin"
  require_relative "lib/school_engine/class_circle"
  require_relative "lib/school_engine/anonymous"
  require_relative "lib/school_engine/expression"
  require_relative "lib/school_engine/tags"
  require_relative "lib/school_engine/featured"
  require_relative "lib/school_engine/messages"
  require_relative "lib/school_engine/group_visibility"
  require_relative "lib/school_engine/class_notice"
  require_relative "lib/school_engine/visibility"

  # ---- 用户自定义字段注册（必须在 after_initialize 内）----
  # 学籍字段（字符串型）
  %w[
    identity graduation_year enrollment_year class_name real_name status junior_class
    contact_phone contact_real_email contact_wechat contact_qq contact_other_social
    gender hobbies teacher_id_last4 real_name_initials
  ].each do |f|
    register_user_custom_field_type(f, :string)
  end

  # 计数 / 时间戳（整型）
  %w[anonymous_violations last_class_change].each do |f|
    register_user_custom_field_type(f, :integer)
  end

  # 联系方式可见性开关（布尔型，存 "t"/"f"）
  %w[
    contact_visibility_phone contact_visibility_real_email
    contact_visibility_wechat contact_visibility_qq contact_visibility_other_social
  ].each do |f|
    register_user_custom_field_type(f, :boolean)
  end

  # 可由用户自助修改的字段（通过 UserUpdater / 自定义资料接口写入）
  %w[gender hobbies contact_phone contact_real_email contact_wechat contact_qq contact_other_social].each do |f|
    register_editable_user_custom_field(f)
  end

  # ---- 路由（通过 Rails::Engine 挂载，让 app/controllers 自动 autoload）----
  Discourse::Application.routes.append { mount ::SchoolEngine::Engine, at: "/" }

  # 首页保持 Discourse 原生 discovery（/ → latest）；
  # "今日话题 + 精选回帖"通过 above-discovery-list-container outlet 以原生组件注入。

  # ---- 事件钩子 ----
  on(:user_created) do |user|
    next unless SiteSetting.school_engine_enabled
    begin
      SchoolEngine::ClassCircle.on_user_created(user)
    rescue => e
      Rails.logger.warn("school-engine: user_created 处理失败 user=#{user&.id}: #{e.message}")
    end
  end

  on(:user_updated) do |user|
    next unless SiteSetting.school_engine_enabled
    begin
      SchoolEngine::ClassCircle.on_user_updated(user)
    rescue => e
      Rails.logger.warn("school-engine: user_updated 处理失败 user=#{user&.id}: #{e.message}")
    end
  end

  # 表白墙分类的帖子/回帖自动标记匿名（真实 user_id 保留，管理员可溯源）
  # + "不给老师看"标记（前端 composer 开关经 school_hide_from_staff 参数传入，仅学生可设置）
  on(:post_created) do |post, opts, _user|
    next unless SiteSetting.school_engine_enabled
    begin
      changed = false

      # 表达空间回帖级匿名（学生、回帖、主动勾选才标记；OP 不可匿名）
      # 旧 confess"整分类自动匿名"已废弃；历史匿名帖（无 anon_label）继续按"匿名用户"掩码
      if SchoolEngine::Expression.post_wants_anonymous?(post, opts) &&
         post.custom_fields["anonymous"] != "true"
        post.custom_fields["anonymous"] = "true"
        SchoolEngine::Expression.assign_anon_label!(post)
        changed = true
      end

      # 匿名墙：整分类强制匿名（主题 OP + 回帖，任何身份，无需勾选）
      if SchoolEngine::Expression.force_wall_anonymous!(post)
        changed = true
      end

      if (opts || {})[:school_hide_from_staff].to_s == "true"
        if post.user && (post.user.staff? || SchoolEngine::Visibility.teacher?(post.user))
          Rails.logger.warn("school-engine: 教师账号不可标记『不给老师看』 post=#{post&.id}")
        else
          post.custom_fields["hide_from_staff"] = "true"
          changed = true
        end
      end

      # 班级通知：仅 staff + 班级圈分类 + 首帖生效，学生/越权标记直接忽略
      notice_marked =
        SchoolEngine::ClassNotice.wants_notice?(post, post.user, opts)
      if notice_marked
        post.custom_fields["class_notice"] = "true"
        changed = true
      end

      post.save_custom_fields(true) if changed

      # 通知帖走标准置顶（pinned），失败不影响发帖
      SchoolEngine::ClassNotice.pin!(post) if notice_marked

      # 引用头掩码：引用匿名帖时清除 cooked 中的头像与真实姓名（跳过回调直接落库）
      masked_cooked = SchoolEngine::Anonymous.mask_quote_headers(post)
      post.update_columns(cooked: masked_cooked) if masked_cooked
    rescue => e
      Rails.logger.warn("school-engine: 帖子可见性标记失败 post=#{post&.id}: #{e.message}")
    end
  end

  # 点赞达阈值：非匿名帖自动入时光胶囊（幂等）
  on(:post_liked) do |post, _post_action|
    next unless SiteSetting.school_engine_enabled
    begin
      SchoolEngine::Featured.auto_capsule_by_likes!(post)
    rescue => e
      Rails.logger.warn("school-engine: 时光胶囊点赞归档失败 post=#{post&.id}: #{e.message}")
    end
  end

  # ---- 序列化补丁（prepend + super，热重载安全）----
  reloadable_patch do
    ::BasicPostSerializer.prepend(SchoolEngine::Anonymous::BasicPostSerializerExtension)
    ::TopicPosterSerializer.prepend(SchoolEngine::Anonymous::TopicPosterSerializerExtension)
    ::TopicListItemSerializer.prepend(SchoolEngine::Anonymous::TopicListItemSerializerExtension)
    ::CategoryAndTopicListsSerializer.prepend(SchoolEngine::Anonymous::CategoryAndTopicListsSerializerExtension)
  end

  # 主题详情 / 帖子流特征字段 / 编辑历史：匿名身份全链路掩码
  reloadable_patch do
    ::TopicViewDetailsSerializer.prepend(SchoolEngine::Anonymous::TopicViewDetailsSerializerExtension)
    ::PostSerializer.prepend(SchoolEngine::Anonymous::PostSerializerExtension)
    ::PostRevisionSerializer.prepend(SchoolEngine::Anonymous::PostRevisionSerializerExtension)
  end

  # 精选：帖子 JSON 暴露 school_featured（staff 帖子菜单据此切换）
  reloadable_patch do
    ::PostSerializer.prepend(SchoolEngine::Featured::PostSerializerExtension)
  end

  # 班级通知：class_notice 帖显示发布者 real_name（BasicPost/Post 序列化）
  reloadable_patch do
    ::BasicPostSerializer.prepend(SchoolEngine::ClassNotice::BasicPostSerializerExtension)
    ::PostSerializer.prepend(SchoolEngine::ClassNotice::PostSerializerExtension)
  end

  # 班级圈群组：非 staff 访问成员列表 404
  reloadable_patch do
    ::GroupsController.prepend(SchoolEngine::GroupVisibility::GroupsControllerExtension)
  end

  # ---- 匿名内容的全链路 SQL 过滤（prepend，热重载安全）----
  reloadable_patch do
    ::TopicQuery.prepend(SchoolEngine::Anonymous::TopicQueryExtension)
    ::UserSummary.prepend(SchoolEngine::Anonymous::UserSummaryExtension)
    ::Search.prepend(SchoolEngine::Anonymous::SearchExtension)
  end

  # ---- "不给老师看"：教师访问隐藏主题/单帖 404，列表对教师过滤 ----
  reloadable_patch do
    ::TopicsController.prepend(SchoolEngine::Visibility::TopicsControllerExtension)
    ::PostsController.prepend(SchoolEngine::Visibility::PostsControllerExtension)
    ::TopicQuery.prepend(SchoolEngine::Visibility::TopicQueryExtension)
  end

  # 个人主页活动流不显示匿名帖（NEW_TOPIC 的 target_post_id 为 -1，用 COALESCE 回退 topic 首帖）
  register_modifier(:user_action_stream_builder) do |builder|
    builder.left_join(
      "post_custom_fields pcf ON pcf.post_id = COALESCE(NULLIF(a.target_post_id, -1), p2.id) AND pcf.name = 'anonymous'",
    )
    builder.where("(pcf.value IS NULL OR pcf.value <> 'true')")
  end

  # 帖子级匿名标记（不输出到 JSON，仅供内部 mask? 判断使用）
  add_to_serializer(:post, :school_anonymous, include_condition: -> { false }) do
    SchoolEngine::Anonymous.mask?(object, scope)
  end

  # 当前用户是否为教师（composer 开关 / 管理界面等前端权限判断用）
  add_to_serializer(:current_user, :school_teacher) do
    SchoolEngine::Visibility.teacher?(object)
  end

  # ---- 隐藏重构后不需要的站点设置项（外部登录 / S3 / 邮件收发 / MaxMind / 广告等）----
  %i[
    enable_google_oauth2_logins google_oauth2_client_id google_oauth2_client_secret
    google_oauth2_prompt google_oauth2_hd google_oauth2_hd_groups_service_account_admin_email
    google_oauth2_hd_groups_service_account_json google_oauth2_hd_groups google_oauth2_verbose_logging
    enable_twitter_logins twitter_consumer_key twitter_consumer_secret
    enable_facebook_logins facebook_app_id facebook_app_secret
    enable_github_logins github_client_id github_client_secret
    enable_discourse_connect discourse_connect_url discourse_connect_secret
    discourse_connect_allowed_redirect_domains discourse_connect_provider_secrets
    discourse_connect_overrides_groups discourse_connect_overrides_bio
    discourse_connect_overrides_avatar discourse_connect_overrides_profile_background
    discourse_connect_overrides_location discourse_connect_overrides_website
    discourse_connect_overrides_card_background discourse_connect_not_approved_url
    enable_s3_uploads enable_direct_s3_uploads s3_access_key_id s3_secret_access_key
    s3_bucket s3_region s3_configure_tombstone_policy s3_use_acls s3_upload_bucket
    s3_cdn_url s3_endpoint s3_proxy_url s3_force_path_style s3_disable_cleanup
    s3_use_iam_profile s3_multipart_upload_threshold s3_multipart_max_parts
    secure_uploads secure_uploads_max_email_embed_image_size_kb
    email_in email_in_allowed_groups email_in_authserv_id email_in_spam_header
    pop3_polling_enabled pop3_polling_ssl pop3_polling_openssl_verify
    pop3_polling_period_mins pop3_polling_host pop3_polling_port
    pop3_polling_username pop3_polling_password pop3_polling_delete_from_server
    maxmind_account_id maxmind_license_key
    house_ads_after_nth_topic house_ads_after_nth_post house_ads_after_nth_root
    house_ads_frequency no_ads_for_personal_messages no_ads_for_categories
    no_ads_for_tags ad_plugin_enable_tracking
    enable_twitter_cards twitter_share_links enable_facebook_cards
  ].each do |name|
    begin
      SiteSetting.hidden_settings_provider.add_hidden(name)
    rescue => e
      Rails.logger.warn("school-engine: 隐藏设置 #{name} 失败: #{e.message}")
    end
  end
end
