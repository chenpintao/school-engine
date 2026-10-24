# frozen_string_literal: true

# 学制引擎管理命令
#   rake school_engine:setup_base      # 只创建教师/毕业生组（名称可在站点设置改；不建任何板块）
#   rake school_engine:seed_categories # 【可选】一键创建默认板块模板（表白墙/匿名墙等，可自行改名删除）
#   rake school_engine:seed_tags       # 【可选】创建表达空间默认标签
#   rake school_engine:sync_all        # 把已有用户同步进各自班级圈
#   rake school_engine:mark_graduates  # 立即执行毕业标记（调试用，正式由 7月1日 cron 触发）
#   rake school_engine:grade[user_id]  # 查看某用户年级/班级圈信息

namespace :school_engine do
  desc "创建基础群组（教师/毕业生，名称取站点设置；不创建任何板块或标签）"
  task setup_base: :environment do
    result = SchoolEngine::ClassCircle.setup_base_structure
    groups = []
    groups << "教师组 #{result[:teachers].name}" if result[:teachers]
    groups << "毕业生组 #{result[:graduates].name}" if result[:graduates]
    puts groups.empty? ? "ℹ️  群组名称设置均为空，未创建任何群组" : "✅ 已就绪：#{groups.join('、')}"
    puts "ℹ️  未创建任何板块。需要默认板块模板时执行 rake school_engine:seed_categories"
    puts "ℹ️  匿名/精选板块绑定在后台设置 school_engine_category_rules 中按 slug 配置"
  end

  desc "【可选】创建默认板块模板：校园闲聊/知识分享/表白墙/匿名墙/校园公告（幂等，可自行改名或删除）"
  task seed_categories: :environment do
    created = SchoolEngine::ClassCircle.seed_default_categories!
    puts created.empty? ? "ℹ️  默认板块均已存在，未新建" : "✅ 已创建板块：#{created.join('、')}"
    puts "ℹ️  这些只是模板，可随时在后台改名/调权限/删除；匿名行为由 school_engine_category_rules 决定"
  end

  desc "【可选】创建表达空间默认标签（碎碎念/今日分享/求助/匿名树洞/校园记录）"
  task seed_tags: :environment do
    tags = SchoolEngine::Tags.ensure_tags!
    puts tags.empty? ? "ℹ️  标签功能已关闭（school_engine_tags_enabled=false）" : "✅ 标签就绪：#{tags.map(&:name).join('、')}"
  end

  desc "把已有用户同步进班级圈（含 Chat 频道）"
  task sync_all: :environment do
    count = 0
    errors = []
    User.human_users.find_each do |user|
      SchoolEngine::ClassCircle.sync_for(user)
      count += 1
    rescue => e
      errors << "#{user.username}: #{e.message}"
    end
    SchoolEngine::ClassCircle.fix_circle_permissions!
    created = SchoolEngine::ClassCircle.ensure_chat_channels!
    puts "✅ 已同步 #{count} 个用户，新建 Chat 频道: #{created.join(', ').presence || '无'}"
    if errors.any?
      puts "⚠️  #{errors.length} 个用户同步失败:"
      errors.each { |e| puts "  - #{e}" }
    end
  end

  desc "立即执行毕业标记（调试用）"
  task mark_graduates: :environment do
    SchoolEngine::ClassCircle.mark_graduates
    puts "✅ 毕业标记已执行"
  end

  desc "查看用户年级信息: rake school_engine:grade[1]"
  task :grade, [:user_id] => :environment do |_, args|
    user = User.find(args[:user_id])
    puts "用户: #{user.username} (#{user.email})"
    puts "毕业年份: #{user.custom_fields['graduation_year']}  班级: #{user.custom_fields['class_name']}"
    puts "状态: #{user.custom_fields['status']}  初中班级: #{user.custom_fields['junior_class']}"
    puts "显示名: #{SchoolEngine::Grade.display_class(user)}"
    puts "所在组: #{user.groups.map(&:name).join(', ')}"
  end
end
