# frozen_string_literal: true

# 学制引擎管理命令
#   rake school_engine:setup_base     # 创建教师/毕业生组 + 四大基础分类（幂等）
#   rake school_engine:sync_all       # 把已有用户同步进各自班级圈
#   rake school_engine:mark_graduates # 立即执行毕业标记（调试用，正式由 7月1日 cron 触发）
#   rake school_engine:grade[user_id] # 查看某用户年级/班级圈信息

namespace :school_engine do
  desc "创建基础结构：教师/毕业生组 + 校园闲聊/知识分享/表白墙/校园公告 分类"
  task setup_base: :environment do
    SchoolEngine::ClassCircle.setup_base_structure
    puts "✅ 基础结构就绪"
  end

  desc "把已有用户同步进班级圈（含 Chat 频道）"
  task sync_all: :environment do
    count = 0
    User.human_users.find_each do |user|
      SchoolEngine::ClassCircle.on_user_created(user)
      count += 1
    end
    SchoolEngine::ClassCircle.fix_circle_permissions!
    created = SchoolEngine::ClassCircle.ensure_chat_channels!
    puts "✅ 已同步 #{count} 个用户，新建 Chat 频道: #{created.join(', ').presence || '无'}"
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
