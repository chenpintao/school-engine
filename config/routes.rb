# frozen_string_literal: true

# 路由定义在 Engine 内，由 plugin.rb 通过 mount ::SchoolEngine::Engine, at: "/" 挂载
# 控制器命名空间为 SchoolEngine（见 isolate_namespace），故 "school_engine#register_user"
# 会解析到 SchoolEngine::SchoolEngineController
SchoolEngine::Engine.routes.draw do
  # ---- SPA 页面 shell（必须排在同路径 JSON API 之前；用 lambda 按请求格式区分）----
  # 浏览器直接访问/刷新（Accept: text/html）→ 页面；XHR 访问 /xxx.json → 落到下方 API
  get "/school/profile" => "school_engine_pages#profile",
      constraints: ->(req) { req.format.html? }
  get "/school/directory" => "school_engine_pages#directory",
      constraints: ->(req) { req.format.html? }
  get "/school/register" => "school_engine_pages#register"
  get "/school/login" => "school_engine_pages#login"
  # 管理页（班级管理组入口；/admin/school-classes 为 staff 后台入口，两者渲染同一 SPA）
  get "/school/manage" => "school_engine_pages#manage", constraints: { format: /html/ }
  get "/school/config" => "school_engine_pages#config_page",
      constraints: ->(req) { req.format.html? }

  # ---- 业务 API ----
  get "/school/home" => "school_engine#home"
  get "/school/feed" => "school_engine#feed"
  get "/school/config" => "school_engine#config"
  put "/school/config" => "school_engine#update_config"
  get "/school/moods/:username" => "school_engine#moods"
  post "/school/mood-checkin" => "school_engine#mood_checkin"
  get "/school/junior-class-status" => "school_engine#junior_class_status"
  post "/school/select-junior-class" => "school_engine#select_junior_class"

  post "/school/register" => "school_engine#register_user"
  post "/school/complete" => "school_engine#complete_registration"
  get "/school/profile" => "school_engine#profile"
  put "/school/profile" => "school_engine#update_profile"
  post "/school/change-password" => "school_engine#change_password"
  post "/school/leave-school" => "school_engine#leave_school"

  # ---- 校园管理 API（staff 或班级管理组，控制器层 ensure_school_admin 校验）----
  get "/school/manage-status" => "school_engine#manage_status"
  get "/school/admin-users" => "school_engine#admin_users"
  put "/school/admin-user" => "school_engine#admin_update_user"
  get "/school/admin-classes" => "school_engine#admin_classes"
  post "/school/admin-fix-displays" => "school_engine#admin_fix_displays"

  get "/school/directory" => "school_engine#directory"
  get "/school/directory.csv" => "school_engine#directory_export"
  get "/school/timeline/:username" => "school_engine#timeline"
  post "/school/feature-post" => "school_engine#feature_post"
  post "/school/unfeature-post" => "school_engine#unfeature_post"
  post "/school/transfer-class" => "school_engine#transfer_class"

  # ---- 管理后台 ----
  get "/admin/school-classes" => "school_engine_pages#admin_page", constraints: ::StaffConstraint.new
end
