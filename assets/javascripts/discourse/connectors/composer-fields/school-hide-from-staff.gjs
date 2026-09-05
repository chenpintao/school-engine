import Component from "@glimmer/component";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import DToggleSwitch from "discourse/ui-kit/d-toggle-switch";

/**
 * 发帖编辑器开关：学生发新主题时可勾选"不给老师看"。
 * 写入 composer.schoolHideFromStaff，经 serializeOnCreate 序列化为请求参数
 * school_hide_from_staff → 后端 post_created 钩子校验后落 custom_fields；
 * 教师访问该主题返回 404，教师主题列表同步过滤。staff / 教师本人不显示此开关。
 */
export default class SchoolHideFromStaff extends Component {
  get composer() {
    return this.args.outletArgs?.model;
  }

  get state() {
    return this.composer?.schoolHideFromStaff === true;
  }

  static shouldRender(outletArgs, context) {
    // 核心 plugin-outlet 会把 outletArgs 本体、helperContext 依次传给 shouldRender
    const currentUser = context?.currentUser;
    const composer = outletArgs?.model;
    if (!currentUser || !composer) {
      return false;
    }
    if (composer.action !== "createTopic") {
      return false;
    }
    return !currentUser.staff && !currentUser.school_teacher;
  }

  @action
  toggle() {
    // DToggleSwitch 渲染 <button role="switch">，无原生 checked，按当前状态取反
    this.composer?.set("schoolHideFromStaff", !this.state);
  }

  <template>
    <div class="school-hide-from-staff">
      <DToggleSwitch
        @state={{this.state}}
        @label="school_engine.hide_from_staff"
        {{on "click" this.toggle}}
      />
    </div>
  </template>
}
