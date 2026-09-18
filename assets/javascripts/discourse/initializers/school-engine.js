import { withPluginApi } from "discourse/lib/plugin-api";
import { ajax } from "discourse/lib/ajax";
import SchoolJuniorClassModal from "discourse/plugins/school-engine/discourse/components/school-junior-class-modal";
import SchoolFeatureButton from "discourse/plugins/school-engine/discourse/components/school-feature-button";

export default {
  name: "school-engine",
  initialize() {
    withPluginApi("1.13.0", (api) => {
        const currentUser = api.getCurrentUser();
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
              ...(currentUser
                ? [
                    new (class extends BaseCustomSidebarSectionLink {
                      get name() {
                        return "school-me";
                      }
                      get href() {
                        return `/u/${currentUser.username}/preferences/profile`;
                      }
                      get title() {
                        return "我的";
                      }
                      get text() {
                        return "我的";
                      }
                      get prefixType() {
                        return "icon";
                      }
                      get prefixValue() {
                        return "user";
                      }
                    })(),
                  ]
                : [
                    new (class extends BaseCustomSidebarSectionLink {
                      get name() {
                        return "school-login";
                      }
                      get route() {
                        return "school-login";
                      }
                      get title() {
                        return "登录";
                      }
                      get text() {
                        return "登录";
                      }
                      get prefixType() {
                        return "icon";
                      }
                      get prefixValue() {
                        return "sign-in-alt";
                      }
                    })(),
                    new (class extends BaseCustomSidebarSectionLink {
                      get name() {
                        return "school-register";
                      }
                      get route() {
                        return "school-register";
                      }
                      get title() {
                        return "注册";
                      }
                      get text() {
                        return "注册";
                      }
                      get prefixType() {
                        return "icon";
                      }
                      get prefixValue() {
                        return "user-plus";
                      }
                    })(),
                  ]),
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
      // 表达空间回帖匿名：composer.schoolAnonymous → school_anonymous 请求参数
      api.serializeOnCreate("school_anonymous", "schoolAnonymous");
      // 班级通知：composer.schoolClassNotice → school_class_notice 请求参数
      api.serializeOnCreate("school_class_notice", "schoolClassNotice");

      // 帖子菜单：staff 精选/取消精选（新版 glimmer post menu DAG；组件内部按分类+回帖条件自渲染）
      api.registerValueTransformer("post-menu-buttons", ({ value: dag, context }) => {
        dag.add("school-feature", SchoolFeatureButton, {
          after: context.firstButtonKey,
        });
      });

      const checked = "__school_junior_checked__";

      // 匿名帖：禁止点击头像/用户名跳转个人主页（全局只需注册一次，避免 onPageChange 累积监听器）
      // 覆盖历史"匿名用户"与表达空间"匿名同学X"（原始链接与 URL 编码两种形态）
      document.addEventListener(
        "click",
        (e) => {
          const a = e.target.closest?.(
            "a[href*='%E5%8C%BF%E5%90%8D%E7%94%A8%E6%88%B7'], a[href*='u/匿名用户'], a[href*='%E5%8C%BF%E5%90%8D%E5%90%8C%E5%AD%A6'], a[href*='u/匿名同学']"
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

        // 班级圈群组页：非 staff 隐藏成员入口与人数（服务端 members 接口已 404，这里仅视觉隐藏）
        const circleGroup = p.match(/^\/g\/((?:xx|cz)-\d{4}-)/);
        const hideCircleMembers =
          !!circleGroup && !api.getCurrentUser()?.staff;
        document.body.classList.toggle("school-circle-group", hideCircleMembers);
        if (hideCircleMembers) {
          // 不依赖具体 DOM 类名：找到指向本班成员页的链接，连同其 tab 容器一起隐藏
          requestAnimationFrame(() => {
            document
              .querySelectorAll('a[href^="/g/xx-"][href$="/members"], a[href^="/g/cz-"][href$="/members"]')
              .forEach((link) => {
                link.style.setProperty("display", "none", "important");
                link
                  .closest('li, [role="tab"], .navigation-tab, .d-button')
                  ?.style.setProperty("display", "none", "important");
              });
          });
        }
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
