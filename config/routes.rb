# frozen_string_literal: true

# 路由定义在 Engine 内，由 plugin.rb 通过 mount ::SchoolEngine::Engine, at: "/" 挂载
# 控制器命名空间为 SchoolEngine（见 isolate_namespace），故 "school_engine#register_user"
# 会解析到 SchoolEngine::SchoolEngineController
SchoolEngine::Engine.routes.draw do
  # ---- 业务 API ----
  get "/school/junior-class-status" => "school_engine#junior_class_status"
  post "/school/select-junior-class" => "school_engine#select_junior_class"

  post "/school/register" => "school_engine#register_user"
  post "/school/complete" => "school_engine#complete_registration"
  # profile/directory 的 JSON API 限定 .json，把无扩展名的 html 直接访问/刷新让给下方 SPA 页面路由
  get "/school/profile" => "school_engine#profile", constraints: { format: /json/ }
  put "/school/profile" => "school_engine#update_profile"
  post "/school/change-password" => "school_engine#change_password"
  post "/school/leave-school" => "school_engine#leave_school"

  # ---- 校园管理 API（staff 或班级管理组，控制器层 ensure_school_admin 校验）----
  get "/school/manage-status" => "school_engine#manage_status"
  get "/school/admin-users" => "school_engine#admin_users"
  put "/school/admin-user" => "school_engine#admin_update_user"
  get "/school/admin-classes" => "school_engine#admin_classes"
  post "/school/admin-fix-displays" => "school_engine#admin_fix_displays"

  get "/school/directory" => "school_engine#directory", constraints: { format: /json/ }
  get "/school/directory.csv" => "school_engine#directory_export"
  get "/school/timeline/:username" => "school_engine#timeline"
  post "/school/feature-post" => "school_engine#feature_post"
  post "/school/unfeature-post" => "school_engine#unfeature_post"
  post "/school/transfer-class" => "school_engine#transfer_class"

  # ---- SPA 页面 shell（由前端路由渲染实际内容）----
  get "/school/register" => "school_engine_pages#register"
  get "/school/login" => "school_engine_pages#login"
  get "/school/profile" => "school_engine_pages#profile", constraints: { format: /html/ }
  get "/school/directory" => "school_engine_pages#directory", constraints: { format: /html/ }
  # 管理页（班级管理组入口；/admin/school-classes 为 staff 后台入口，两者渲染同一 SPA）
  get "/school/manage" => "school_engine_pages#manage", constraints: { format: /html/ }

  # ---- 管理后台 ----
  get "/admin/school-classes" => "school_engine_pages#admin_page", constraints: ::StaffConstraint.new
end
