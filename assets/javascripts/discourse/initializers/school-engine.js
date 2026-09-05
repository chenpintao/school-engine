import { withPluginApi } from "discourse/lib/plugin-api";
import { ajax } from "discourse/lib/ajax";
import SchoolJuniorClassModal from "discourse/plugins/school-engine/discourse/components/school-junior-class-modal";

export default {
  name: "school-engine",
  initialize() {
    withPluginApi("1.13.0", (api) => {
      // 同学录/班级圈：左侧菜单（sidebar）入口（必须传 panelKey "main"，否则 section 被静默丢弃）
      api.addSidebarSection(
        (BaseCustomSidebarSection, BaseCustomSidebarSectionLink) => {
          return class extends BaseCustomSidebarSection {
            get name() {
              return "school";
            }
            get text() {
              return "校园";
            }
            get links() {
            return [
              new (class extends BaseCustomSidebarSectionLink {
                get name() {
                  return "school-directory";
                }
                get route() {
                  return "school-directory";
                }
                get title() {
                  return "同学录";
                }
                get text() {
                  return "同学录";
                }
                get prefixType() {
                  return "icon";
                }
                get prefixValue() {
                  return "address-book";
                }
              })(),
              new (class extends BaseCustomSidebarSectionLink {
                get name() {
                  return "school-classes";
                }
                get route() {
                  return "groups";
                }
                get title() {
                  return "班级圈";
                }
                get text() {
                  return "班级圈";
                }
                get prefixType() {
                  return "icon";
                }
                get prefixValue() {
                  return "user-group";
                }
              })(),
              new (class extends BaseCustomSidebarSectionLink {
                get name() {
                  return "school-manage";
                }
                get route() {
                  return "school-manage";
                }
                get title() {
                  return "班级管理";
                }
                get text() {
                  return "班级管理";
                }
                get prefixType() {
                  return "icon";
                }
                get prefixValue() {
                  return "users";
                }
              })(),
            ];
          }
        };
      },
      "main"
      );

      // 班级管理：admin 管理菜单入口
      api.addAdminSidebarSectionLink("root", {
        name: "school-classes",
        route: "admin.schoolClasses",
        label: "school_engine.admin_menu_label",
        description: "school_engine.admin_menu_description",
        icon: "users",
      });

      // "不给老师看"开关：composer.schoolHideFromStaff → 创建主题请求参数
      // school_hide_from_staff（参照 discourse-post-voting 的官方模式，
      // 后端经 add_permitted_post_create_param 放行，避免弃用的 meta_data 通道）
      api.serializeOnCreate("school_hide_from_staff", "schoolHideFromStaff");

      const checked = "__school_junior_checked__";

      // 匿名帖：禁止点击头像/用户名跳转个人主页（全局只需注册一次，避免 onPageChange 累积监听器）
      document.addEventListener(
        "click",
        (e) => {
          const a = e.target.closest?.(
            "a[href*='%E5%8C%BF%E5%90%8D%E7%94%A8%E6%88%B7'], a[href*='u/匿名用户']"
          );
          if (a) {
            e.preventDefault();
            e.stopPropagation();
          }
        },
        true
      );

      api.onPageChange(() => {
        // 登录/注册入口统一指向自定义页面（覆盖 header 按钮、/login /signup 路由、直接访问）
        const p = window.location.pathname;
        if (p === "/login" || p === "/login/") {
          window.location.replace("/school/login");
          return;
        }
        if (p === "/signup" || p === "/signup/") {
          window.location.replace("/school/register");
          return;
        }
        // 个人设置保留原生框架：profile 内容由插件注入（user-preferences-profile outlet）

        // 小升初选班检测（登录用户，只查一次）
        const user = api.getCurrentUser();
        if (!user || window[checked]) return;
        window[checked] = true;

        ajax("/school/junior-class-status.json")
          .then((data) => {
            if (data && data.needs) {
              const modal = api.container.lookup("service:modal");
              modal.show(SchoolJuniorClassModal, {
                model: { classes: ["1班", "2班", "3班", "4班", "5班", "6班"] },
              });
            }
          })
          .catch(() => {});
      });
    });
  },
};
