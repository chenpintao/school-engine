import DiscourseRoute from "discourse/routes/discourse";
import { service } from "@ember/service";

/**
 * 自定义登录页。
 * 已登录用户访问 /school/login 时直接回到首页，避免停在登录页。
 * 注意：不在 routeWillChange 里拦截 school-login 自身，防止重定向循环。
 */
export default class SchoolLoginRoute extends DiscourseRoute {
  @service router;
  @service currentUser;

  beforeModel() {
    if (this.currentUser) {
      this.router.replaceWith("discovery.latest");
    }
  }
}
