import Component from "@glimmer/component";
import SchoolProfileForm from "discourse/plugins/school-engine/discourse/components/school-profile-form";

/**
 * 注入到 user-preferences-profile outlet：用学籍+联系方式组件代替原生字段。
 * 仅在已登录用户的个人设置中渲染。
 */
export default class SchoolProfile extends Component {
  static shouldRender(args, context) {
    return context.currentUser;
  }

  <template>
    <SchoolProfileForm />
  </template>
}
